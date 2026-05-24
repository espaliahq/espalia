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
  description "Fetch one capability's detail plus the assessee's per-level ratings (self/manager/aligned)."
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
  def capability
    @capability ||= FrameworkState::Capability
      .joins(:category)
      .where(framework_capability_categories: { framework_id: assignment.framework_id })
      .includes(:category)
      .find_by!(capability_id: params[:capability_id])
  end

  EMPTY_RATING = { self: nil, manager: nil, aligned: nil }.freeze

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
        aligned: row.aligned_frequency
      }
    end
    index.default = EMPTY_RATING
    index
  end
end
