# frozen_string_literal: true

# A person's lifecycle history on one framework, from their event stream
# ({Assessments::LifecycleTimeline}) — every alignment started, completed and
# re-opened, cycle joins and exits, role and level changes, the reporting
# manager, explorations and rating delegations, each with when and who. The
# read models keep only the latest of each; this is the full record.
#
# Read-only; scoped by AssessmentPolicy#show? (the assessee, their manager
# chain, active delegates and tenant admins). Free-text reasons — why someone
# was unenrolled, unassigned or moved, why a delegation was granted — were
# written about the assessee, for the people around them, so the assessee's
# own read leaves them out.
class Operations::Assessments::Timeline < Operations::Base
  include Operations::LifecyclePayload

  description "A person's lifecycle history on one assessment, oldest first, from their event stream: " \
              "assignment to the framework and removal from it, cycle joins, exits and conclusions, every " \
              "alignment started, completed and re-opened (per role, with role_id, role_code, role_name and " \
              "home — whether it was the role they held when they joined the cycle), role, level and " \
              "reporting-manager changes, explorations started and closed, and manager-rating delegations " \
              "granted and revoked — each with occurred_at (ISO 8601 UTC) and the actor. Unlike " \
              "assessments_get and reporting_cycle_cohort, which keep only the latest stamp, this answers " \
              "when an alignment was first completed and how often it was re-opened. Self and manager " \
              "assessment completion have no event: they appear with derived: true, at their latest " \
              "completion only. Pass cycle_id for one cycle's milestones, and kinds to narrow by kind (an " \
              "empty list returns none). Free-text reasons are left out when the assessee reads their own. " \
              "Returns no rating values."
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
  #   by kind — `role_id` / `role_code` / `role_name` / `home`,
  #   `framework_version`, `reason`, `outcome`, from/to roles and levels, a
  #   manager, a delegate or an exploration
  # @raise [Operations::Base::ParameterError] for a kind it doesn't know
  def perform
    milestones = Assessments::LifecycleTimeline.new(assignment: assignment)
      .call(cycle_id: params[:cycle_id].presence, kinds: kinds)
    lookups = Lookups.new(milestones)
    { assignment_id: assignment.id, milestones: milestones.map { |m| milestone_payload(m, lookups) } }
  end

  # Every person, role, level and cycle the milestones name, loaded once.
  class Lookups
    # @return [Hash{String => String}] person id => name
    attr_reader :people
    # @return [Hash{String => FrameworkState::Role}]
    attr_reader :roles
    # @return [Hash{String => FrameworkState::Level}]
    attr_reader :levels
    # @return [Hash{String => String}] cycle id => name
    attr_reader :cycles

    # @param milestones [Array<Assessments::LifecycleTimeline::Milestone>]
    def initialize(milestones)
      details = milestones.map(&:details)
      @people = names(Person, :id, milestones.map(&:actor_id) +
        details.flat_map { |d| d.values_at(:manager_id, :previous_manager_id, :delegate_person_id) })
      @roles = index(FrameworkState::Role, :role_id, milestones.map(&:role_id) +
        details.flat_map { |d| d.values_at(:role_id, :previous_role_id, :new_role_id, :target_role_id) })
      @levels = index(FrameworkState::Level, :level_id,
        details.flat_map { |d| d.values_at(:level_id, :previous_level_id, :new_level_id) })
      @cycles = names(AssessmentCycle, :cycle_id, milestones.map(&:cycle_id))
    end

    private

    def names(model, key, ids)
      ids = ids.compact.uniq
      ids.empty? ? {} : model.where(key => ids).pluck(key, :name).to_h
    end

    def index(model, key, ids)
      ids = ids.compact.uniq
      ids.empty? ? {} : model.where(key => ids).index_by(&key)
    end
  end

  private

  def assignment
    @assignment ||= PersonFrameworkAssignment.find(params[:assignment_id])
  end

  # nil keeps every kind; an empty list keeps none.
  def kinds
    return nil if params[:kinds].nil?

    requested = Array(params[:kinds])
    unknown = requested - Assessments::LifecycleTimeline::KINDS
    raise ParameterError, "unknown kinds: #{unknown.join(', ')}" if unknown.any?

    requested
  end

  def assessee_reading?
    context.person&.id == assignment.person_id
  end

  def milestone_payload(milestone, lookups)
    {
      kind: milestone.kind,
      occurred_at: lifecycle_time(milestone.occurred_at),
      actor: lifecycle_actor(milestone.actor_id, lookups.people),
      cycle: milestone.cycle_id && { id: milestone.cycle_id, name: lookups.cycles[milestone.cycle_id] },
      derived: milestone.derived,
      **alignment_fields(milestone, lookups),
      **detail_fields(milestone.details, lookups)
    }
  end

  # The role-alignment vocabulary assessments_get and reporting_cycle_cohort use.
  def alignment_fields(milestone, lookups)
    return {} unless milestone.role_id

    role = lookups.roles[milestone.role_id]
    { role_id: milestone.role_id, role_code: role&.code, role_name: role&.name, home: milestone.home,
      level_ordinal: milestone.details[:level_ordinal] }.compact
  end

  def detail_fields(details, lookups)
    {
      framework_version: details[:framework_version],
      reason: assessee_reading? ? nil : details[:reason],
      outcome: details[:outcome],
      source: details[:source],
      exploration_id: details[:exploration_id],
      role: details[:role_id] && role(details[:role_id], lookups),
      level: details[:level_id] && level(details[:level_id], lookups),
      target_role: details[:target_role_id] && role(details[:target_role_id], lookups),
      target_level_ordinal: details[:target_level_ordinal],
      from_role: details[:previous_role_id] && role(details[:previous_role_id], lookups),
      to_role: details[:new_role_id] && role(details[:new_role_id], lookups),
      from_level: details[:previous_level_id] && level(details[:previous_level_id], lookups),
      to_level: details[:new_level_id] && level(details[:new_level_id], lookups),
      manager: lifecycle_actor(details[:manager_id], lookups.people),
      previous_manager: lifecycle_actor(details[:previous_manager_id], lookups.people),
      delegate: lifecycle_actor(details[:delegate_person_id], lookups.people),
      expires_at: expires_at(details[:expires_at])
    }.compact
  end

  # Stored as the event serializer wrote it; reported like every other time.
  def expires_at(value)
    return nil if value.blank?

    lifecycle_time(value.is_a?(String) ? Time.zone.parse(value) : value.to_time)
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
