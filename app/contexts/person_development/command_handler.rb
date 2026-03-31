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

  # Opens a new assessment cycle.
  #
  # @param person_id [String] UUID of the person
  # @param framework_id [String] UUID of the framework
  # @param cycle_id [String] UUID for the new cycle
  # @param cycle_name [String] display name
  # @param cycle_type [String] one of: regular, performance_review, promotion_review
  # @param framework_version [Integer] the framework version
  def open_assessment_cycle(person_id, framework_id, cycle_id, cycle_name, cycle_type, framework_version)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.open_assessment_cycle(cycle_id, cycle_name, cycle_type, framework_version)
    end
  end

  # Records a self-rating for a capability at a specific level.
  #
  # @param person_id [String] UUID of the person
  # @param framework_id [String] UUID of the framework
  # @param capability_stable_id [String] stable UUID of the capability
  # @param level_ordinal [Integer] the level being assessed
  # @param frequency [String] "some", "occasional", or "consistent"
  # @param comment [String, nil] optional rationale
  def rate_self(person_id, framework_id, capability_stable_id, level_ordinal:, frequency:, comment: nil)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.rate_self(capability_stable_id, level_ordinal: level_ordinal, frequency: frequency, comment: comment)
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
  # @param comment [String, nil] optional comment
  def revise_self_rating(person_id, framework_id, capability_stable_id, level_ordinal:, frequency:, rationale:, comment: nil)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.revise_self_rating(capability_stable_id, level_ordinal: level_ordinal,
        frequency: frequency, rationale: rationale, comment: comment)
    end
  end

  # Clears a previous self-rating.
  #
  # @param person_id [String] UUID of the person
  # @param framework_id [String] UUID of the framework
  # @param capability_stable_id [String] stable UUID of the capability
  # @param level_ordinal [Integer] the level being cleared
  def clear_self_rating(person_id, framework_id, capability_stable_id, level_ordinal:)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.clear_self_rating(capability_stable_id, level_ordinal: level_ordinal)
    end
  end

  # Records a manager's rating for a person's capability at a specific level.
  #
  # @param person_id [String] UUID of the person being rated
  # @param framework_id [String] UUID of the framework
  # @param capability_stable_id [String] stable UUID of the capability
  # @param level_ordinal [Integer] the level being assessed
  # @param frequency [String] "some", "occasional", or "consistent"
  # @param comment [String, nil] optional rationale
  def rate_as_manager(person_id, framework_id, capability_stable_id, level_ordinal:, frequency:, comment: nil)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.rate_as_manager(capability_stable_id, level_ordinal: level_ordinal, frequency: frequency, comment: comment)
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
  # @param comment [String, nil] optional comment
  def revise_manager_rating(person_id, framework_id, capability_stable_id, level_ordinal:, frequency:, rationale:, comment: nil)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.revise_manager_rating(capability_stable_id, level_ordinal: level_ordinal,
        frequency: frequency, rationale: rationale, comment: comment)
    end
  end

  # Clears a previous manager rating.
  #
  # @param person_id [String] UUID of the person being rated
  # @param framework_id [String] UUID of the framework
  # @param capability_stable_id [String] stable UUID of the capability
  # @param level_ordinal [Integer] the level being cleared
  def clear_manager_rating(person_id, framework_id, capability_stable_id, level_ordinal:)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.clear_manager_rating(capability_stable_id, level_ordinal: level_ordinal)
    end
  end

  # Records an agreed assessment for a capability at a specific level.
  #
  # @param person_id [String] UUID of the person
  # @param framework_id [String] UUID of the framework
  # @param capability_stable_id [String] stable UUID of the capability
  # @param level_ordinal [Integer] the level being agreed upon
  # @param aligned_frequency [String] agreed frequency
  # @param comment [String, nil] optional comment
  def align_assessment(person_id, framework_id, capability_stable_id, level_ordinal:, aligned_frequency:, comment: nil)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.align_assessment(capability_stable_id, level_ordinal: level_ordinal,
        aligned_frequency: aligned_frequency, comment: comment)
    end
  end

  # Completes the current assessment cycle.
  #
  # @param person_id [String] UUID of the person
  # @param framework_id [String] UUID of the framework
  # @param cycle_id [String] UUID of the cycle to complete
  def complete_assessment_cycle(person_id, framework_id, cycle_id)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.complete_assessment_cycle(cycle_id)
    end
  end
end
