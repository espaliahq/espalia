# frozen_string_literal: true

# Drill-in for one capability within an assessment. Returns the framework
# capability detail unchanged (delegated to {Mcp::FrameworkSerializer})
# plus a per-expectation ratings overlay sourced from
# {AssessmentLevelRating}.
#
# Read-only; scoped by AssessmentPolicy#show?
# (owns_assessment? || manages_assessee?).
#
# The base capability payload is a strict subset of this payload — same
# keys, same nesting — so an LLM that learned the framework capability
# shape needs zero new schema knowledge to consume it. Each expectation
# row gains a `ratings:` key with the assessee's self / manager / aligned
# values for that level (nil when not yet rated).
class Operations::Assessments::CapabilityGet < Operations::Base
  description "Fetch one capability's detail plus the assessee's per-level ratings (self/manager/aligned). " \
              "Accepts either capability_id (version-specific) or stable_id (cross-version) in the capability_id argument."
  category :read
  approval :none

  parameter :assignment_id, String, required: true
  parameter :capability_id, String, required: true

  def policy_check
    authorize assignment, :show?
  end

  # @return [Hash] same as {Operations::Frameworks::CapabilityGet}, with
  #   each entry in `expectations` gaining `ratings: { self:, manager:, aligned: }`
  #   (each value a frequency string or nil), plus a `cycle_id` at the
  #   top level naming the cycle the ratings are scoped to (nil when
  #   the assessee has no open cycle).
  def perform
    base = Mcp::FrameworkSerializer.capability(assignment.framework, capability)
    cycle = assignment.current_open_cycle
    ratings_index = ratings_by_level(cycle)

    base.merge(
      cycle_id: cycle&.cycle_id,
      expectations: base[:expectations].map { |e| e.merge(ratings: ratings_index[e[:level_ordinal]]) }
    )
  end

  private

  def assignment
    @assignment ||= PersonFrameworkAssignment.find(params[:assignment_id])
  end

  # Scope the lookup through the assignment's framework so a
  # capability_id from a different framework in the same tenant can't
  # be requested under this assignment's authorization.
  #
  # LLM clients regularly pass `stable_id` (the cross-version handle
  # also returned by parent calls like assessments_get) into the
  # `capability_id` argument — both are UUID-shaped and the LLM picks
  # whichever feels more semantically stable. We look up by either,
  # within the framework's category scope.
  def capability
    @capability ||= begin
      scope = FrameworkState::Capability
        .joins(:category)
        .where(framework_capability_categories: { framework_id: assignment.framework_id })
        .includes(:category)
      identifier = params[:capability_id]
      scope.find_by(capability_id: identifier) || scope.find_by!(stable_id: identifier)
    end
  end

  EMPTY_RATING = { self: nil, manager: nil, aligned: nil,
                   self_carried: false, manager_carried: false }.freeze

  def ratings_by_level(cycle)
    return Hash.new(EMPTY_RATING) unless cycle

    rows = AssessmentLevelRating.where(
      cycle_id: cycle.cycle_id,
      person_id: assignment.person_id,
      capability_stable_id: capability.stable_id
    )
    index = rows.each_with_object({}) do |row, h|
      h[row.level_ordinal] = {
        self: row.self_rated_frequency,
        manager: row.manager_rated_frequency,
        aligned: row.aligned_frequency,
        # Carried-forward (seeded, unconfirmed) provenance per side — an
        # MCP client should present these as "carried from the previous
        # cycle", matching the web's dashed-pill treatment.
        self_carried: row.self_rating_carried?,
        manager_carried: row.manager_rating_carried?
      }
    end
    index.default = EMPTY_RATING
    index
  end
end
