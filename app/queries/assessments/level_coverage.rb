# frozen_string_literal: true

# Computes whether a person's CURRENT-LEVEL capabilities are fully rated for
# each perspective (self / manager / aligned) within an assessment cycle.
#
# This is the durable "Assessment Complete" signal: the
# {PersonDevelopment::Projections::CurrentAssessment} projection runs it on
# every rating change and stamps the result onto
# {AssessmentCycleProgress#self_completed_at} / `#manager_completed_at`, which
# the /assessments list then reads cheaply. The aligned perspective backs the
# alignment-completion gate: {Assessments::AlignmentCompletionsController}
# refuses to mark alignment complete while any current-level cell lacks an
# agreed value, so `aligned` status always means the formal record is whole.
#
# The denominator is the role's {Assessments::RoleScope} at the assessed
# level — the same cells {Assessments::MatrixDataBuilder} renders — so the
# list badge and the show-page pill never drift.
#
# @example
#   Assessments::LevelCoverage.new(
#     person_id: p.id, framework_id: fw_id, cycle_id: cycle_id
#   ).call(include_aligned: true)
#   # => { self_complete: true, manager_complete: false, aligned_complete: false,
#   #      total: 18, self_rated: 18, manager_rated: 12, aligned_rated: 0 }
#
class Assessments::LevelCoverage
  # @param person_id [String]
  # @param framework_id [String]
  # @param cycle_id [String]
  def initialize(person_id:, framework_id:, cycle_id:)
    @person_id = person_id
    @framework_id = framework_id
    @cycle_id = cycle_id
  end

  # @param include_aligned [Boolean] also count the aligned perspective.
  #   Opt-in because the hottest caller — the CurrentAssessment projection,
  #   on every rating event (and every event of a replay) — only consumes
  #   the self/manager sides; the aligned COUNT is paid solely by the
  #   completion gate.
  # @return [Hash] { self_complete:, manager_complete:, total:, self_rated:,
  #   manager_rated: } — plus { aligned_complete:, aligned_rated:,
  #   current_level_cell_keys: } when include_aligned is true.
  #   `current_level_cell_keys` are `[capability_stable_id, level_ordinal]`
  #   pairs for every counted cell — the completion gate forwards them into
  #   the aggregate so the coverage check re-runs atomically against the
  #   stream (see {PersonDevelopment::Aggregate#complete_alignment}).
  def call(include_aligned: false)
    ordinal = assessed_level_ordinal
    return empty(include_aligned:) if ordinal.nil?

    scope = Assessments::RoleScope.for(role_id: role_id, framework_id: @framework_id).at_level(ordinal)
    return empty(include_aligned:) if scope.empty?

    stable_ids = scope.capability_stable_ids
    ratings = AssessmentLevelRating
      .where(person_id: @person_id, framework_id: @framework_id, cycle_id: @cycle_id)
      .within(scope)
    # Completion means VETTED THIS CYCLE: carried-forward (seeded) values
    # hold real data but nobody has confirmed them, so they don't count
    # toward the self/manager "Complete" signals. A confirm/revise flips a
    # side's provenance to "human" and it starts counting; nil provenance
    # (legacy rows, factories) is treated as human — only "seeded" is
    # excluded. The ALIGNED side below stays value-based: agreed values are
    # never seeded.
    self_rated = ratings.where.not(self_rated_frequency: nil)
      .where(self_rating_source: [ nil, "human" ])
      .distinct.count(:capability_stable_id)
    manager_rated = ratings.where.not(manager_rated_frequency: nil)
      .where(manager_rating_source: [ nil, "human" ])
      .distinct.count(:capability_stable_id)
    total = stable_ids.size

    result = {
      self_complete: self_rated == total,
      manager_complete: manager_rated == total,
      total: total,
      self_rated: self_rated,
      manager_rated: manager_rated
    }
    if include_aligned
      aligned_rated = ratings.where.not(aligned_frequency: nil).distinct.count(:capability_stable_id)
      result[:aligned_complete] = aligned_rated == total
      result[:aligned_rated] = aligned_rated
      result[:current_level_cell_keys] = stable_ids.map { |sid| [ sid, ordinal ] }
    end
    result
  end

  private

  def empty(include_aligned: false)
    result = { self_complete: false, manager_complete: false,
               total: 0, self_rated: 0, manager_rated: 0 }
    result.merge!(aligned_complete: false, aligned_rated: 0, current_level_cell_keys: []) if include_aligned
    result
  end

  def assignment
    @assignment ||= PersonFrameworkAssignment.find_by(person_id: @person_id, framework_id: @framework_id)
  end

  def role_id
    assignment&.role_id
  end

  # Prefers the cycle's enrollment snapshot level (same-role gate) over the live
  # assignment level — mirrors MatrixDataBuilder#resolve_assessment_level so a
  # later promotion never re-interprets the cycle.
  #
  # @return [Integer, nil]
  def assessed_level_ordinal
    return nil unless assignment

    enrollment = AssessmentCycleEnrollment.find_by(cycle_id: @cycle_id, person_id: @person_id)
    return enrollment.level_ordinal if enrollment&.level_ordinal && enrollment.role_id == role_id

    FrameworkState::Level.find_by(level_id: assignment.level_id)&.ordinal
  end
end
