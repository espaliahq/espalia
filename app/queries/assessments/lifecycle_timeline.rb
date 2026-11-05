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
# Historical events lack fields added since (ADR-22's `role_id`, ADR-18's
# actors): a missing role is the cycle's home role, and a missing actor
# falls back to the metadata `actor_id`, then nil.
#
# @example
#   Assessments::LifecycleTimeline.new(assignment: assignment).call(kinds: %w[alignment_reopened])
class Assessments::LifecycleTimeline
  Milestone = Data.define(:kind, :occurred_at, :actor_id, :cycle_id, :role_id, :home, :derived, :details)

  EVENTS = {
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

  DERIVED_KINDS = %w[self_assessment_completed manager_assessment_completed].freeze
  KINDS = (EVENTS.values + DERIVED_KINDS).freeze
  ALIGNMENT_KINDS = %w[alignment_started alignment_completed alignment_reopened].freeze

  ACTOR_KEYS = {
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
  # @param kinds [Array<String>, nil] keep only these kinds (see {KINDS})
  # @return [Array<Milestone>] oldest first
  def call(cycle_id: nil, kinds: nil)
    milestones = event_milestones + derived_milestones
    milestones = milestones.select { |m| m.cycle_id == cycle_id } if cycle_id
    milestones = milestones.select { |m| kinds.include?(m.kind) } if kinds
    milestones.sort_by { |m| [ m.occurred_at, KINDS.index(m.kind) ] }
  end

  private

  def event_milestones
    stream = EventStreamNaming.person_development_stream(@assignment.person_id, @assignment.framework_id)
    @event_store.read.stream(stream).of_type(EVENTS.keys).to_a.map { |event| milestone_for(event) }
  end

  def milestone_for(event)
    kind = EVENTS.fetch(event.class)
    data = event.data.with_indifferent_access
    cycle_id = data[:cycle_id]
    alignment = ALIGNMENT_KINDS.include?(kind)
    role_id = alignment ? data[:role_id] || home_role_id(cycle_id) : nil

    Milestone.new(
      kind: kind,
      occurred_at: event.metadata[:timestamp],
      actor_id: (ACTOR_KEYS[kind] && data[ACTOR_KEYS[kind]]) || event.metadata[:actor_id],
      cycle_id: cycle_id,
      role_id: role_id,
      home: alignment ? role_id == home_role_id(cycle_id) : nil,
      derived: false,
      details: data.slice(*DETAIL_KEYS.fetch(kind, [])).symbolize_keys
    )
  end

  def derived_milestones
    AssessmentCycleProgress.where(person_id: @assignment.person_id, cycle_id: cycle_ids).flat_map do |progress|
      [
        derived("self_assessment_completed", progress.self_completed_at, progress.cycle_id),
        derived("manager_assessment_completed", progress.manager_completed_at, progress.cycle_id)
      ].compact
    end
  end

  def derived(kind, time, cycle_id)
    time && Milestone.new(kind: kind, occurred_at: time, actor_id: nil, cycle_id: cycle_id,
                          role_id: nil, home: nil, derived: true, details: {})
  end

  # The cycles of this framework the person enrolled in.
  def cycle_ids
    @cycle_ids ||= enrollments.keys
  end

  # The role a cycle assesses the person in: its enrollment snapshot, else
  # the live assignment's — as CurrentAssessment resolves a role-less event.
  def home_role_id(cycle_id)
    enrollments[cycle_id]&.role_id || @assignment.role_id
  end

  def enrollments
    @enrollments ||= AssessmentCycleEnrollment.for_person(@assignment.person_id)
      .joins(:cycle).where(assessment_cycles: { framework_id: @assignment.framework_id })
      .index_by(&:cycle_id)
  end
end
