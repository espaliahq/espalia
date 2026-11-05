# frozen_string_literal: true

# When one participation reached each home-role milestone, read from its
# enrollment and progress rows. The read models keep only the latest of
# each: a re-open clears `aligned_at`, and the completion stamps come from
# `Assessments::LevelCoverage` on rating events, which counts human ratings
# against the live assignment's role — so they can disagree with the cohort
# funnel's `self_done` / `manager_done` until the next rating.
#
# @example
#   Assessments::Lifecycle.from(enrollment: enrollment, progress: progress).aligned_at
Assessments::Lifecycle = Data.define(
  :enrolled_at, :started_at, :self_completed_at, :manager_completed_at,
  :alignment_started_at, :alignment_started_by_id,
  :aligned_at, :aligned_by_id, :aligned_framework_version
) do
  # @param enrollment [AssessmentCycleEnrollment]
  # @param progress [AssessmentCycleProgress, nil] absent until the person joins
  # @return [Assessments::Lifecycle]
  def self.from(enrollment:, progress:)
    new(
      enrolled_at: enrollment.enrolled_at,
      started_at: progress&.started_at,
      self_completed_at: progress&.self_completed_at,
      manager_completed_at: progress&.manager_completed_at,
      alignment_started_at: progress&.alignment_started_at,
      alignment_started_by_id: progress&.alignment_started_by_id,
      aligned_at: progress&.aligned_at,
      aligned_by_id: progress&.aligned_by_id,
      # A re-join resets aligned_at but leaves the version behind.
      aligned_framework_version: progress&.aligned_at && progress.aligned_framework_version
    )
  end

  # @return [Float, nil]
  def days_to_align
    return nil unless aligned_at && enrolled_at

    (aligned_at - enrolled_at) / 1.day
  end

  # @return [Array<String>] the people this lifecycle names
  def actor_ids
    [ alignment_started_by_id, aligned_by_id ].compact
  end
end
