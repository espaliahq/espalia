# frozen_string_literal: true

# One person's lifecycle history on one framework, read from their
# PersonDevelopment stream at call time — the facts the read models
# overwrite. A re-open clears `aligned_at` and the next completion replaces
# it; the stream still holds every `FullAlignmentCompleted` and
# `AlignmentReopened`, so this is where "when was it first aligned?" and
# "how many times was it re-opened?" are answered.
#
# Self and manager completion have no event (they are derived from
# coverage), so they come from the progress stamps — the latest only — and
# are marked `derived`.
#
# A cycle's home role is the one the aggregate holds (`@home_role_id`): the
# role held at the join, moved by a transfer until any alignment starts in
# the cycle (https://github.com/mr-yum/growth-os/issues/687). So the stream
# is replayed: assignment and role changes track the role, a join records it,
# and a transfer moves it while the cycle is unpinned. Historical events
# lack fields added since (ADR-22's `role_id`, ADR-18's actors): a missing
# role is the cycle's home role, and a missing actor falls back to the
# metadata `actor_id`, then nil.
#
# @example
#   Assessments::LifecycleTimeline.new(assignment: assignment).call(kinds: %w[alignment_reopened])
class Assessments::LifecycleTimeline
  # One milestone. `position` is its place in the stream, the order ties
  # keep; `home` is set on alignment milestones only.
  Milestone = Data.define(:kind, :occurred_at, :actor_id, :cycle_id, :role_id, :home, :derived, :details, :position)

  EVENTS = {
    PersonDevelopment::Events::PersonAssignedToFramework => "assigned_to_framework",
    PersonDevelopment::Events::PersonUnassignedFromFramework => "unassigned_from_framework",
    PersonDevelopment::Events::JoinedAssessmentCycle => "joined_cycle",
    PersonDevelopment::Events::LeftAssessmentCycle => "left_cycle",
    PersonDevelopment::Events::AssessmentCycleConcluded => "cycle_concluded",
    PersonDevelopment::Events::AlignmentStarted => "alignment_started",
    PersonDevelopment::Events::FullAlignmentCompleted => "alignment_completed",
    PersonDevelopment::Events::AlignmentReopened => "alignment_reopened",
    PersonDevelopment::Events::PersonRoleChanged => "role_changed",
    PersonDevelopment::Events::PersonLevelChanged => "level_changed",
    PersonDevelopment::Events::ReportingManagerRecorded => "reporting_manager_recorded",
    PersonDevelopment::Events::ExplorationStarted => "exploration_started",
    PersonDevelopment::Events::ExplorationClosed => "exploration_closed",
    PersonDevelopment::Events::ManagerRatingDelegated => "manager_rating_delegated",
    PersonDevelopment::Events::ManagerRatingDelegationRevoked => "manager_rating_delegation_revoked"
  }.freeze

  # The events that decide a cycle's home role, read whatever kinds are asked for.
  HOME_TRACKING = [
    PersonDevelopment::Events::PersonAssignedToFramework,
    PersonDevelopment::Events::PersonRoleChanged,
    PersonDevelopment::Events::PersonUnassignedFromFramework,
    PersonDevelopment::Events::JoinedAssessmentCycle,
    PersonDevelopment::Events::LeftAssessmentCycle,
    PersonDevelopment::Events::AssessmentCycleConcluded,
    PersonDevelopment::Events::AlignmentStarted
  ].freeze

  DERIVED_KINDS = %w[self_assessment_completed manager_assessment_completed].freeze
  KINDS = (EVENTS.values + DERIVED_KINDS).freeze
  ALIGNMENT_KINDS = %w[alignment_started alignment_completed alignment_reopened].freeze

  ACTOR_KEYS = {
    "assigned_to_framework" => :assigned_by,
    "unassigned_from_framework" => :unassigned_by,
    "alignment_started" => :started_by_id,
    "alignment_completed" => :completed_by_id,
    "alignment_reopened" => :reopened_by_id,
    "role_changed" => :changed_by,
    "level_changed" => :changed_by,
    "exploration_started" => :started_by_id,
    "exploration_closed" => :closed_by_id,
    "manager_rating_delegated" => :granted_by_id,
    "manager_rating_delegation_revoked" => :revoked_by_id
  }.freeze

  DETAIL_KEYS = {
    "assigned_to_framework" => %i[role_id level_id],
    "unassigned_from_framework" => %i[previous_role_id previous_level_id reason],
    "joined_cycle" => %i[framework_version],
    "left_cycle" => %i[reason],
    "alignment_started" => %i[level_ordinal],
    "alignment_completed" => %i[framework_version],
    "role_changed" => %i[previous_role_id new_role_id previous_level_id new_level_id reason],
    "level_changed" => %i[previous_level_id new_level_id reason],
    "reporting_manager_recorded" => %i[manager_id previous_manager_id source],
    "exploration_started" => %i[exploration_id target_role_id target_level_ordinal],
    "exploration_closed" => %i[exploration_id outcome],
    "manager_rating_delegated" => %i[delegate_person_id expires_at reason],
    "manager_rating_delegation_revoked" => %i[delegate_person_id]
  }.freeze

  # @param assignment [PersonFrameworkAssignment]
  # @param event_store [RailsEventStore::Client]
  def initialize(assignment:, event_store: Rails.configuration.event_store)
    @assignment = assignment
    @event_store = event_store
  end

  # @param cycle_id [String, nil] keep only the milestones of this cycle
  # @param kinds [Array<String>, nil] keep only these kinds (see {KINDS}); nil keeps all
  # @return [Array<Milestone>] oldest first; ties keep stream order
  def call(cycle_id: nil, kinds: nil)
    kinds ||= KINDS
    milestones = event_milestones(kinds) + derived_milestones(kinds)
    milestones = milestones.select { |m| m.cycle_id == cycle_id } if cycle_id
    milestones.sort_by { |m| [ m.occurred_at, m.position ] }
  end

  private

  def event_milestones(kinds)
    wanted = EVENTS.select { |_, kind| kinds.include?(kind) }.keys
    return [] if wanted.empty?

    stream = EventStreamNaming.person_development_stream(@assignment.person_id, @assignment.framework_id)
    events = @event_store.read.stream(stream).of_type((wanted + HOME_TRACKING).uniq).to_a

    role_id = nil
    current_cycle_id = nil
    pinned = Set.new
    home_roles = {}
    events.each_with_index.filter_map do |event, position|
      data = event.data.with_indifferent_access
      case event
      when PersonDevelopment::Events::PersonAssignedToFramework then role_id = data[:role_id]
      when PersonDevelopment::Events::PersonUnassignedFromFramework then role_id = nil
      when PersonDevelopment::Events::PersonRoleChanged
        role_id = data[:new_role_id]
        home_roles[current_cycle_id] = role_id if current_cycle_id && !pinned.include?(current_cycle_id)
      when PersonDevelopment::Events::JoinedAssessmentCycle
        current_cycle_id = data[:cycle_id]
        pinned.delete(current_cycle_id)
        home_roles[current_cycle_id] = role_id
      when PersonDevelopment::Events::LeftAssessmentCycle, PersonDevelopment::Events::AssessmentCycleConcluded
        current_cycle_id = nil
      when PersonDevelopment::Events::AlignmentStarted then pinned << data[:cycle_id]
      end
      milestone_for(event, data, position, home_roles) if wanted.include?(event.class)
    end
  end

  def milestone_for(event, data, position, home_roles)
    kind = EVENTS.fetch(event.class)
    cycle_id = data[:cycle_id]
    alignment = ALIGNMENT_KINDS.include?(kind)
    home_role_id = home_roles.fetch(cycle_id) { @assignment.role_id }
    role_id = alignment ? data[:role_id] || home_role_id : nil

    Milestone.new(
      kind: kind,
      occurred_at: event.metadata[:timestamp],
      actor_id: (ACTOR_KEYS[kind] && data[ACTOR_KEYS[kind]]) || event.metadata[:actor_id],
      cycle_id: cycle_id,
      role_id: role_id,
      home: alignment ? role_id == home_role_id : nil,
      derived: false,
      details: data.slice(*DETAIL_KEYS.fetch(kind, [])).symbolize_keys,
      position: position
    )
  end

  # Derived after every event at the same instant: the stamp follows the
  # rating that completed the side.
  def derived_milestones(kinds)
    return [] if (kinds & DERIVED_KINDS).empty?

    cycle_ids = AssessmentCycleEnrollment.for_person(@assignment.person_id)
      .joins(:cycle).where(assessment_cycles: { framework_id: @assignment.framework_id }).pluck(:cycle_id)
    AssessmentCycleProgress.where(person_id: @assignment.person_id, cycle_id: cycle_ids).flat_map do |progress|
      [
        kinds.include?("self_assessment_completed") && derived("self_assessment_completed", progress.self_completed_at, progress.cycle_id),
        kinds.include?("manager_assessment_completed") && derived("manager_assessment_completed", progress.manager_completed_at, progress.cycle_id)
      ].select(&:itself)
    end
  end

  def derived(kind, time, cycle_id)
    time && Milestone.new(kind: kind, occurred_at: time, actor_id: nil, cycle_id: cycle_id, role_id: nil,
                          home: nil, derived: true, details: {}, position: Float::INFINITY)
  end
end
