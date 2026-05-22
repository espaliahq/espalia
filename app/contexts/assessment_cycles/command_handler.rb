# frozen_string_literal: true

# Handles commands for the AssessmentCycles aggregate.
#
# Loads the aggregate via the repository, executes the command,
# and stores resulting events.
#
class AssessmentCycles::CommandHandler
  # @param repository [AssessmentCycles::Repository]
  def initialize(repository: AssessmentCycles::Repository.new)
    @repository = repository
  end

  # Defines a new assessment cycle.
  #
  # @param cycle_id [String] UUID for the cycle
  # @param framework_id [String] UUID of the framework
  # @param name [String] display name
  # @param cycle_type [String] regular | performance_review | promotion_review
  # @param framework_version [Integer] the framework version to freeze against
  # @param defined_by [String, nil] optional person_id / tenant_user_id
  # @param planned_end_at [String, Date, nil] soft target completion date
  def define_cycle(cycle_id, framework_id, name, cycle_type, framework_version,
                   defined_by: nil, planned_end_at: nil)
    @repository.with_cycle(cycle_id) do |cycle|
      cycle.define(cycle_id, framework_id, name, cycle_type, framework_version,
                   defined_by: defined_by, planned_end_at: planned_end_at)
    end
  end

  # Renames an existing open cycle.
  #
  # @param cycle_id [String]
  # @param new_name [String]
  # @param updated_by [String, nil]
  def rename_cycle(cycle_id, new_name, updated_by: nil)
    @repository.with_cycle(cycle_id) do |cycle|
      cycle.rename(new_name, updated_by: updated_by)
    end
  end

  # Changes the type of an existing open cycle.
  #
  # @param cycle_id [String]
  # @param new_cycle_type [String]
  # @param updated_by [String, nil]
  def change_cycle_type(cycle_id, new_cycle_type, updated_by: nil)
    @repository.with_cycle(cycle_id) do |cycle|
      cycle.change_type(new_cycle_type, updated_by: updated_by)
    end
  end

  # Sets, changes, or clears the planned end date.
  #
  # @param cycle_id [String]
  # @param planned_end_at [String, Date, nil] nil clears any previously-set value
  # @param updated_by [String, nil]
  def set_cycle_planned_end(cycle_id, planned_end_at, updated_by: nil)
    @repository.with_cycle(cycle_id) do |cycle|
      cycle.set_planned_end(planned_end_at, updated_by: updated_by)
    end
  end

  # Enrolls a person in the cycle.
  #
  # @param cycle_id [String] UUID of the cycle
  # @param person_id [String] UUID of the person to enroll
  # @param enrolled_by [String, nil] optional person_id / tenant_user_id
  def enroll(cycle_id, person_id, enrolled_by: nil)
    @repository.with_cycle(cycle_id) do |cycle|
      cycle.enroll(person_id, enrolled_by: enrolled_by)
    end
  end

  # Removes a person from the cycle.
  #
  # @param cycle_id [String] UUID of the cycle
  # @param person_id [String] UUID of the person to unenroll
  # @param reason [String] why the person is being removed
  # @param unenrolled_by [String, nil] optional person_id / tenant_user_id
  def unenroll(cycle_id, person_id, reason, unenrolled_by: nil)
    @repository.with_cycle(cycle_id) do |cycle|
      cycle.unenroll(person_id, reason, unenrolled_by: unenrolled_by)
    end
  end

  # Closes the cycle.
  #
  # @param cycle_id [String] UUID of the cycle
  # @param closed_by [String, nil] optional person_id / tenant_user_id
  def close_cycle(cycle_id, closed_by: nil)
    @repository.with_cycle(cycle_id) do |cycle|
      cycle.close(closed_by: closed_by)
    end
  end
end
