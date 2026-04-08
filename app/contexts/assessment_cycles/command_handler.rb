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
  def define_cycle(cycle_id, framework_id, name, cycle_type, framework_version, defined_by: nil)
    @repository.with_cycle(cycle_id) do |cycle|
      cycle.define(cycle_id, framework_id, name, cycle_type, framework_version, defined_by: defined_by)
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
