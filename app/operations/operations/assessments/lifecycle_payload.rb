# frozen_string_literal: true

# When a participation reached each milestone, in the field names
# `reporting_cycle_cohort` uses, so an agent reads one vocabulary across the
# assessment and reporting tools. Including Operations call
# {#lifecycle_payload} and {#role_alignment_times} after resolving every
# actor they name with {#actor_names}.
module Operations::Assessments::LifecyclePayload
  private

  # @param enrollment [AssessmentCycleEnrollment]
  # @param progress [AssessmentCycleProgress, nil] absent until the person joins
  # @param actors [Hash{String => String}] person id => name
  # @return [Hash]
  def lifecycle_payload(enrollment, progress, actors)
    {
      enrolled_at: lifecycle_time(enrollment.enrolled_at),
      started_at: lifecycle_time(progress&.started_at),
      self_completed_at: lifecycle_time(progress&.self_completed_at),
      manager_completed_at: lifecycle_time(progress&.manager_completed_at),
      alignment_started_at: lifecycle_time(progress&.alignment_started_at),
      alignment_started_by: lifecycle_actor(progress&.alignment_started_by_id, actors),
      aligned_at: lifecycle_time(progress&.aligned_at),
      aligned_by: lifecycle_actor(progress&.aligned_by_id, actors),
      # A re-join resets aligned_at but leaves the version behind.
      aligned_framework_version: progress&.aligned_at && progress.aligned_framework_version
    }
  end

  # @param row [AssessmentCycleRoleAlignment]
  # @param actors [Hash{String => String}]
  # @return [Hash]
  def role_alignment_times(row, actors)
    {
      alignment_started_at: lifecycle_time(row.alignment_started_at),
      alignment_started_by: lifecycle_actor(row.alignment_started_by_id, actors),
      aligned_at: lifecycle_time(row.aligned_at),
      aligned_by: lifecycle_actor(row.aligned_by_id, actors),
      reopened_at: lifecycle_time(row.reopened_at),
      reopened_by: lifecycle_actor(row.reopened_by_id, actors)
    }
  end

  # @param progresses [Array<AssessmentCycleProgress>]
  # @param rows [Array<AssessmentCycleRoleAlignment>]
  # @return [Hash{String => String}] person id => name
  def actor_names(progresses, rows)
    ids = progresses.compact.flat_map { |p| [ p.alignment_started_by_id, p.aligned_by_id ] } +
      rows.flat_map { |r| [ r.alignment_started_by_id, r.aligned_by_id, r.reopened_by_id ] }
    ids = ids.compact.uniq
    ids.empty? ? {} : Person.where(id: ids).pluck(:id, :name).to_h
  end

  def lifecycle_actor(id, actors)
    id && { id: id, name: actors[id] }
  end

  def lifecycle_time(time)
    time&.utc&.iso8601
  end
end
