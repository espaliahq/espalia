# frozen_string_literal: true

# A person's lifecycle history on one framework, from their event stream
# ({Assessments::LifecycleTimeline}) — every alignment started, completed and
# re-opened, cycle joins and exits, role and level changes, the reporting
# manager, explorations and rating delegations, each with when and who. The
# read models keep only the latest of each; this is the full record.
#
# Read-only; scoped by AssessmentPolicy#show? (the assessee, their manager
# chain, active delegates and tenant admins).
class Operations::Assessments::Timeline < Operations::Base
  description "A person's lifecycle history on one assessment, oldest first, from their event stream: every " \
              "alignment started, completed and re-opened (per role; home says whether it was their home " \
              "role), cycle joins, exits and conclusions, role and level changes, reporting-manager changes, " \
              "explorations started and closed, and manager-rating delegations granted and revoked — each " \
              "with occurred_at (ISO 8601 UTC) and the actor. Unlike assessments_get and " \
              "reporting_cycle_cohort, which keep only the latest stamp, this answers when an alignment was " \
              "first completed and how often it was re-opened. Self and manager assessment completion have " \
              "no event: they appear with derived: true, at their latest completion only. Pass cycle_id for " \
              "one cycle's milestones, and kinds to narrow by kind. Returns no rating values."
  category :read
  approval :none

  parameter :assignment_id, String, required: true
  parameter :cycle_id, String, required: false, allow_blank: false,
    schema: { description: "Keep only the milestones of this cycle (from reporting_cycles_list or assessments_get)." }
  parameter :kinds, Array, required: false,
    schema: { type: "array", items: { type: "string", enum: Assessments::LifecycleTimeline::KINDS },
              description: "Keep only these kinds of milestone." }

  # @raise [Pundit::NotAuthorizedError] when the caller may not view the assessment
  def policy_check
    authorize assignment, :show?
  end

  # @return [Hash] `{ assignment_id:, milestones: [...] }`, oldest first. Each
  #   milestone has `kind`, `occurred_at`, `actor`, `cycle`, `derived`, and —
  #   by kind — `role` and `home`, `framework_version`, `reason`, `outcome`,
  #   from/to roles and levels, a manager, a delegate or an exploration
  # @raise [Operations::Base::ParameterError] for a kind it doesn't know
  def perform
    milestones = Assessments::LifecycleTimeline.new(assignment: assignment)
      .call(cycle_id: params[:cycle_id].presence, kinds: kinds)
    lookups = Lookups.new(milestones)
    { assignment_id: assignment.id, milestones: milestones.map { |m| milestone_payload(m, lookups) } }
  end

  # Every person, role, level and cycle the milestones name, loaded once.
  class Lookups
    attr_reader :people, :roles, :levels, :cycles

    # @param milestones [Array<Assessments::LifecycleTimeline::Milestone>]
    def initialize(milestones)
      details = milestones.map(&:details)
      @people = names(Person, :id, milestones.map(&:actor_id) +
        details.flat_map { |d| d.values_at(:manager_id, :previous_manager_id, :delegate_person_id) })
      @roles = FrameworkState::Role.where(role_id: (milestones.map(&:role_id) +
        details.flat_map { |d| d.values_at(:previous_role_id, :new_role_id, :target_role_id) }).compact.uniq)
        .index_by(&:role_id)
      @levels = FrameworkState::Level.where(level_id: details.flat_map { |d| d.values_at(:previous_level_id, :new_level_id) }
        .compact.uniq).index_by(&:level_id)
      @cycles = names(AssessmentCycle, :cycle_id, milestones.map(&:cycle_id))
    end

    private

    def names(model, key, ids)
      ids = ids.compact.uniq
      ids.empty? ? {} : model.where(key => ids).pluck(key, :name).to_h
    end
  end

  private

  def assignment
    @assignment ||= PersonFrameworkAssignment.find(params[:assignment_id])
  end

  def kinds
    return nil if params[:kinds].blank?

    unknown = Array(params[:kinds]) - Assessments::LifecycleTimeline::KINDS
    raise ParameterError, "unknown kinds: #{unknown.join(', ')}" if unknown.any?

    Array(params[:kinds])
  end

  def milestone_payload(milestone, lookups)
    details = milestone.details
    {
      kind: milestone.kind,
      occurred_at: milestone.occurred_at&.utc&.iso8601,
      actor: person(milestone.actor_id, lookups),
      cycle: milestone.cycle_id && { id: milestone.cycle_id, name: lookups.cycles[milestone.cycle_id] },
      derived: milestone.derived,
      **role_fields(milestone, lookups),
      **detail_fields(details, lookups)
    }
  end

  def role_fields(milestone, lookups)
    return {} unless milestone.role_id

    { role: role(milestone.role_id, lookups), home: milestone.home, level_ordinal: milestone.details[:level_ordinal] }.compact
  end

  def detail_fields(details, lookups)
    {
      framework_version: details[:framework_version],
      reason: details[:reason],
      outcome: details[:outcome],
      source: details[:source],
      exploration_id: details[:exploration_id],
      target_role: details[:target_role_id] && role(details[:target_role_id], lookups),
      target_level_ordinal: details[:target_level_ordinal],
      from_role: details[:previous_role_id] && role(details[:previous_role_id], lookups),
      to_role: details[:new_role_id] && role(details[:new_role_id], lookups),
      from_level: details[:previous_level_id] && level(details[:previous_level_id], lookups),
      to_level: details[:new_level_id] && level(details[:new_level_id], lookups),
      manager: person(details[:manager_id], lookups),
      previous_manager: person(details[:previous_manager_id], lookups),
      delegate: person(details[:delegate_person_id], lookups),
      expires_at: details[:expires_at]
    }.compact
  end

  def person(id, lookups)
    id && { id: id, name: lookups.people[id] }
  end

  def role(id, lookups)
    found = lookups.roles[id]
    { id: id, code: found&.code, name: found&.name }
  end

  def level(id, lookups)
    found = lookups.levels[id]
    { id: id, ordinal: found&.ordinal, title: found&.title }
  end
end
