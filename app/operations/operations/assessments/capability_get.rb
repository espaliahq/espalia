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
# values for that level (nil when not yet rated), and the payload carries
# a `score:` key — this capability's own number on the level-independent
# scale (ADR-21), the same one its card shows.
class Operations::Assessments::CapabilityGet < Operations::Base
  description "Fetch one capability's detail, the assessee's per-level ratings (self/manager/aligned), and the capability's own score on the same level-independent scale. Accepts either capability_id (version-specific) or stable_id (cross-version) in the capability_id argument."
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
    ratings_index = ratings_by_level(cycle, hide_others: hide_others?(cycle))

    base.merge(
      cycle_id: cycle&.cycle_id,
      score: score_summary.capability(capability.stable_id),
      expectations: base[:expectations].map { |e| e.merge(ratings: ratings_index[e[:level_ordinal]]) }
    )
  end

  private

  # Same perspective resolution as the web and as `assessments_get`, so
  # one capability's number can't disagree with the assessment's.
  def score_summary
    @score_summary ||= Assessments::ScoreSummary.new(
      assignment: assignment,
      context: Assessments::ViewerContext.for(assignment: assignment, authorization: context)
    )
  end

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

  # Self-assessment privacy (assessments.md): the assessee must not see
  # the manager's rating — or its carried provenance — until alignment
  # formally begins. Mirrors Assessments::MatrixDataBuilder#hide_others?.
  # Manager-chain viewers and admins pass AssessmentPolicy#show? as
  # non-assessees and are never scrubbed.
  def hide_others?(cycle)
    return false unless context.person&.id == assignment.person_id
    return true unless cycle

    status = AssessmentCycleParticipation.find_by(
      cycle_id: cycle.cycle_id, person_id: assignment.person_id
    )&.status
    !%w[aligning aligned].include?(status)
  end

  def ratings_by_level(cycle, hide_others:)
    return Hash.new(EMPTY_RATING) unless cycle

    # Phase 2 of the role lens adds `in_role:` so a client can tell whether
    # this capability counts for the assessed role (ADR-22).
    rows = AssessmentLevelRating.across_all_roles.where(
      cycle_id: cycle.cycle_id,
      person_id: assignment.person_id,
      capability_stable_id: capability.stable_id
    )
    index = rows.each_with_object({}) do |row, h|
      h[row.level_ordinal] = {
        self: row.self_rated_frequency,
        manager: hide_others ? nil : row.manager_rated_frequency,
        aligned: hide_others ? nil : row.aligned_frequency,
        # Carried-forward (seeded, unconfirmed) provenance per side — an
        # MCP client should present these as "carried from the previous
        # cycle", matching the web's dashed-pill treatment. Same privacy
        # gate as the values themselves.
        self_carried: row.self_rating_carried?,
        manager_carried: hide_others ? false : row.manager_rating_carried?
      }
    end
    index.default = EMPTY_RATING
    index
  end
end
