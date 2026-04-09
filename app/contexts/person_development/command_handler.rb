# frozen_string_literal: true

# Handles commands for the PersonDevelopment aggregate.
#
# Loads the aggregate via the repository, executes the command,
# and stores resulting events.
#
class PersonDevelopment::CommandHandler
  # @param repository [PersonDevelopment::Repository]
  def initialize(repository: PersonDevelopment::Repository.new)
    @repository = repository
  end

  # Assigns a person to a framework with a role and level.
  #
  # @param person_id [String] UUID of the person
  # @param framework_id [String] UUID of the framework
  # @param role_id [String] UUID of the assigned role
  # @param level_id [String] UUID of the assigned level
  def assign_to_framework(person_id, framework_id, role_id, level_id)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.assign_to_framework(person_id, framework_id, role_id, level_id)
    end
  end

  # Changes a person's role (and level) within their current framework.
  #
  # @param person_id [String] UUID of the person
  # @param framework_id [String] UUID of the framework
  # @param new_role_id [String] UUID of the new role
  # @param new_level_id [String] UUID of the new level
  # @param reason [String] why the change occurred
  def change_person_role(person_id, framework_id, new_role_id, new_level_id, reason: "hris_sync")
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.change_role(new_role_id, new_level_id, reason: reason)
    end
  end

  # Changes a person's level within the same role (promotion).
  #
  # @param person_id [String] UUID of the person
  # @param framework_id [String] UUID of the framework
  # @param new_level_id [String] UUID of the new level
  # @param reason [String] why the change occurred
  def change_person_level(person_id, framework_id, new_level_id, reason: "hris_sync")
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.change_level(new_level_id, reason: reason)
    end
  end

  # Adds the person to an assessment cycle.
  #
  # Called ONLY by {AssessmentCycles::SyncHandlers::PersonEnrollmentSync}
  # in response to a PersonEnrolled event — never by controllers.
  #
  # @param person_id [String] UUID of the person
  # @param framework_id [String] UUID of the framework
  # @param cycle_id [String] UUID of the cycle to join
  # @param framework_version [Integer] framework version the cycle assesses against
  def join_cycle(person_id, framework_id, cycle_id, framework_version)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.join_cycle(cycle_id, framework_version)
    end
  end

  # Removes the person from their current assessment cycle.
  #
  # Called ONLY by {AssessmentCycles::SyncHandlers::PersonEnrollmentSync}
  # in response to a PersonUnenrolled or CycleClosed event — never by controllers.
  #
  # @param person_id [String] UUID of the person
  # @param framework_id [String] UUID of the framework
  # @param cycle_id [String] UUID of the cycle being left (must match current)
  # @param reason [String] why the person is leaving
  def leave_cycle(person_id, framework_id, cycle_id, reason)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.leave_cycle(cycle_id, reason)
    end
  end

  # Records a self-rating for a capability at a specific level.
  #
  # @param person_id [String] UUID of the person
  # @param framework_id [String] UUID of the framework
  # @param capability_stable_id [String] stable UUID of the capability
  # @param level_ordinal [Integer] the level being assessed
  # @param frequency [String] "some", "occasional", or "consistent"
  # @param cycle_id [String] UUID of the cycle this rating belongs to
  # @param comment [String, nil] optional rationale
  def rate_self(person_id, framework_id, capability_stable_id, level_ordinal:, frequency:, cycle_id:, comment: nil)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.rate_self(capability_stable_id, level_ordinal: level_ordinal,
        frequency: frequency, cycle_id: cycle_id, comment: comment)
    end
  end

  # Revises a previous self-rating.
  #
  # @param person_id [String] UUID of the person
  # @param framework_id [String] UUID of the framework
  # @param capability_stable_id [String] stable UUID of the capability
  # @param level_ordinal [Integer] the level being revised
  # @param frequency [String] revised frequency
  # @param rationale [String] reason for the change
  # @param cycle_id [String] UUID of the cycle this rating belongs to
  # @param comment [String, nil] optional comment
  def revise_self_rating(person_id, framework_id, capability_stable_id,
                         level_ordinal:, frequency:, rationale:, cycle_id:, comment: nil)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.revise_self_rating(capability_stable_id, level_ordinal: level_ordinal,
        frequency: frequency, rationale: rationale, cycle_id: cycle_id, comment: comment)
    end
  end

  # Clears a previous self-rating.
  #
  # @param person_id [String] UUID of the person
  # @param framework_id [String] UUID of the framework
  # @param capability_stable_id [String] stable UUID of the capability
  # @param level_ordinal [Integer] the level being cleared
  # @param cycle_id [String] UUID of the cycle this rating belongs to
  def clear_self_rating(person_id, framework_id, capability_stable_id, level_ordinal:, cycle_id:)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.clear_self_rating(capability_stable_id, level_ordinal: level_ordinal, cycle_id: cycle_id)
    end
  end

  # Records a manager's rating for a person's capability at a specific level.
  #
  # @param person_id [String] UUID of the person being rated
  # @param framework_id [String] UUID of the framework
  # @param capability_stable_id [String] stable UUID of the capability
  # @param level_ordinal [Integer] the level being assessed
  # @param frequency [String] "some", "occasional", or "consistent"
  # @param cycle_id [String] UUID of the cycle this rating belongs to
  # @param comment [String, nil] optional rationale
  def rate_as_manager(person_id, framework_id, capability_stable_id,
                      level_ordinal:, frequency:, cycle_id:, comment: nil)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.rate_as_manager(capability_stable_id, level_ordinal: level_ordinal,
        frequency: frequency, cycle_id: cycle_id, comment: comment)
    end
  end

  # Revises a previous manager rating.
  #
  # @param person_id [String] UUID of the person being rated
  # @param framework_id [String] UUID of the framework
  # @param capability_stable_id [String] stable UUID of the capability
  # @param level_ordinal [Integer] the level being revised
  # @param frequency [String] revised frequency
  # @param rationale [String] reason for the change
  # @param cycle_id [String] UUID of the cycle this rating belongs to
  # @param comment [String, nil] optional comment
  def revise_manager_rating(person_id, framework_id, capability_stable_id,
                            level_ordinal:, frequency:, rationale:, cycle_id:, comment: nil)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.revise_manager_rating(capability_stable_id, level_ordinal: level_ordinal,
        frequency: frequency, rationale: rationale, cycle_id: cycle_id, comment: comment)
    end
  end

  # Clears a previous manager rating.
  #
  # @param person_id [String] UUID of the person being rated
  # @param framework_id [String] UUID of the framework
  # @param capability_stable_id [String] stable UUID of the capability
  # @param level_ordinal [Integer] the level being cleared
  # @param cycle_id [String] UUID of the cycle this rating belongs to
  def clear_manager_rating(person_id, framework_id, capability_stable_id, level_ordinal:, cycle_id:)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.clear_manager_rating(capability_stable_id, level_ordinal: level_ordinal, cycle_id: cycle_id)
    end
  end

  # Records an agreed assessment for a capability at a specific level.
  #
  # @param person_id [String] UUID of the person
  # @param framework_id [String] UUID of the framework
  # @param capability_stable_id [String] stable UUID of the capability
  # @param level_ordinal [Integer] the level being agreed upon
  # @param aligned_frequency [String] agreed frequency
  # @param cycle_id [String] UUID of the cycle this alignment belongs to
  # @param comment [String, nil] optional comment
  def align_assessment(person_id, framework_id, capability_stable_id,
                       level_ordinal:, aligned_frequency:, cycle_id:, comment: nil)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.align_assessment(capability_stable_id, level_ordinal: level_ordinal,
        aligned_frequency: aligned_frequency, cycle_id: cycle_id, comment: comment)
    end
  end
end
