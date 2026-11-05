# frozen_string_literal: true

# When a participation reached each milestone, and each role alignment's
# times, as one vocabulary for `reporting_cycle_cohort` and `assessments_get`.
# Including Operations resolve every person and role the payloads name in
# bulk ({#person_names}, {#roles_for}) and pass the lookups in.
module Operations::LifecyclePayload
  private

  # @param lifecycle [Assessments::Lifecycle]
  # @param actors [Hash{String => String}] person id => name
  # @return [Hash]
  def lifecycle_payload(lifecycle, actors)
    {
      enrolled_at: lifecycle_time(lifecycle.enrolled_at),
      started_at: lifecycle_time(lifecycle.started_at),
      self_completed_at: lifecycle_time(lifecycle.self_completed_at),
      manager_completed_at: lifecycle_time(lifecycle.manager_completed_at),
      alignment_started_at: lifecycle_time(lifecycle.alignment_started_at),
      alignment_started_by: lifecycle_actor(lifecycle.alignment_started_by_id, actors),
      aligned_at: lifecycle_time(lifecycle.aligned_at),
      aligned_by: lifecycle_actor(lifecycle.aligned_by_id, actors),
      aligned_framework_version: lifecycle.aligned_framework_version
    }
  end

  # @param row [AssessmentCycleRoleAlignment]
  # @param roles [Hash{String => FrameworkState::Role}]
  # @param actors [Hash{String => String}]
  # @return [Hash]
  def role_alignment_payload(row, roles, actors)
    role = roles[row.role_id]
    { role_id: row.role_id, role_code: role&.code, role_name: role&.name, level_ordinal: row.level_ordinal,
      home: row.home, status: row.status, **role_alignment_times(row, actors) }
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

  # @param lifecycles [Array<Assessments::Lifecycle>]
  # @param rows [Array<AssessmentCycleRoleAlignment>]
  # @return [Hash{String => String}] person id => name, for everyone they name
  def person_names(lifecycles, rows)
    ids = lifecycles.flat_map(&:actor_ids) +
      rows.flat_map { |row| [ row.alignment_started_by_id, row.aligned_by_id, row.reopened_by_id ] }
    ids = ids.compact.uniq
    ids.empty? ? {} : Person.where(id: ids).pluck(:id, :name).to_h
  end

  # @param rows [Array<AssessmentCycleRoleAlignment>]
  # @return [Hash{String => FrameworkState::Role}]
  def roles_for(rows)
    role_ids = rows.map(&:role_id).uniq
    role_ids.empty? ? {} : FrameworkState::Role.where(role_id: role_ids).index_by(&:role_id)
  end

  def lifecycle_actor(id, actors)
    id && { id: id, name: actors[id] }
  end

  def lifecycle_time(time)
    time&.getutc&.iso8601
  end
end
