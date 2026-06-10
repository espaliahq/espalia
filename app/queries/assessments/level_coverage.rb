# frozen_string_literal: true

# Computes whether a person's CURRENT-LEVEL capabilities are fully rated for
# each perspective (self / manager) within an assessment cycle.
#
# This is the durable "Assessment Complete" signal: the
# {PersonDevelopment::Projections::CurrentAssessment} projection runs it on
# every rating change and stamps the result onto
# {AssessmentCycleProgress#self_completed_at} / `#manager_completed_at`, which
# the /assessments list then reads cheaply.
#
# The denominator mirrors {Assessments::MatrixDataBuilder} exactly — active,
# role-bound capabilities that have a behavioural expectation at the assessed
# level — so the list badge and the show-page pill never drift.
#
# @example
#   Assessments::LevelCoverage.new(
#     person_id: p.id, framework_id: fw_id, cycle_id: cycle_id
#   ).call
#   # => { self_complete: true, manager_complete: false, total: 18,
#   #      self_rated: 18, manager_rated: 12 }
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

  # @return [Hash] { self_complete:, manager_complete:, total:, self_rated:, manager_rated: }
  def call
    ordinal = assessed_level_ordinal
    return empty if ordinal.nil?

    stable_ids = current_level_capability_stable_ids(ordinal)
    return empty if stable_ids.empty?

    ratings = AssessmentLevelRating.where(
      person_id: @person_id, framework_id: @framework_id, cycle_id: @cycle_id,
      level_ordinal: ordinal, capability_stable_id: stable_ids
    )
    self_rated = ratings.where.not(self_rated_frequency: nil).distinct.count(:capability_stable_id)
    manager_rated = ratings.where.not(manager_rated_frequency: nil).distinct.count(:capability_stable_id)
    total = stable_ids.size

    {
      self_complete: self_rated == total,
      manager_complete: manager_rated == total,
      total: total,
      self_rated: self_rated,
      manager_rated: manager_rated
    }
  end

  private

  def empty
    { self_complete: false, manager_complete: false, total: 0, self_rated: 0, manager_rated: 0 }
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

  # stable_ids of active, role-bound capabilities with an expectation at the
  # assessed level — the coverage denominator.
  #
  # @param ordinal [Integer]
  # @return [Array<String>]
  def current_level_capability_stable_ids(ordinal)
    bound_ids = FrameworkState::CapabilityRoleBinding.where(role_id: role_id).pluck(:capability_id)
    return [] if bound_ids.empty?

    cap_ids = FrameworkState::BehaviouralExpectation
      .where(capability_id: bound_ids, level_ordinal: ordinal)
      .pluck(:capability_id)
    return [] if cap_ids.empty?

    FrameworkState::Capability
      .joins(:category)
      .where(capability_id: cap_ids, status: "active")
      .where(framework_capability_categories: { framework_id: @framework_id })
      .pluck(:stable_id)
  end
end
