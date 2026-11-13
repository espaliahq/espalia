# frozen_string_literal: true

# Handles commands for Org Graph person aggregates.
#
# Each method loads the person's stream, runs the command, and stores the
# resulting events. Every command names its provider and effective date.
#
class OrgGraph::CommandHandler
  # @param repository [OrgGraph::Repository]
  def initialize(repository: OrgGraph::Repository.new)
    @repository = repository
  end

  # Records a person the Org Graph has not seen before.
  #
  # @param person_id [String] UUID of the person
  # @param facts [Hash] keywords accepted by {OrgGraph::PersonAggregate#record}
  def record_person(person_id, **facts)
    @repository.with_person(person_id) { |person| person.record(person_id, **facts) }
  end

  # @param person_id [String]
  # @param provider [String]
  # @param effective_on [Date, String] their start date
  def join(person_id, provider:, effective_on:)
    @repository.with_person(person_id) { |person| person.join(provider:, effective_on:) }
  end

  # @param person_id [String]
  # @param provider [String]
  # @param effective_on [Date, String] their leaving date
  def leave(person_id, provider:, effective_on:)
    @repository.with_person(person_id) { |person| person.leave(provider:, effective_on:) }
  end

  # @param person_id [String]
  # @param provider [String]
  # @param effective_on [Date, String] their return date
  def return_to_work(person_id, provider:, effective_on:)
    @repository.with_person(person_id) { |person| person.return_to_work(provider:, effective_on:) }
  end

  # @param person_id [String]
  # @param title [String, nil]
  def change_title(person_id, title, provider:, effective_on:)
    @repository.with_person(person_id) { |person| person.change_title(title, provider:, effective_on:) }
  end

  # @param person_id [String]
  # @param level [String, nil] the provider's level, before any framework mapping
  def change_level(person_id, level, provider:, effective_on:)
    @repository.with_person(person_id) { |person| person.change_level(level, provider:, effective_on:) }
  end

  # @param person_id [String]
  # @param manager_id [String, nil] person_id of the new manager, or nil for none
  def change_manager(person_id, manager_id, provider:, effective_on:)
    @repository.with_person(person_id) { |person| person.change_manager(manager_id, provider:, effective_on:) }
  end

  # @param person_id [String]
  # @param cost_centre [String, nil]
  def change_cost_centre(person_id, cost_centre, provider:, effective_on:)
    @repository.with_person(person_id) { |person| person.change_cost_centre(cost_centre, provider:, effective_on:) }
  end

  # @param person_id [String]
  # @param site [String, nil]
  # @param country [String, nil]
  def change_site(person_id, site:, country:, provider:, effective_on:)
    @repository.with_person(person_id) { |person| person.change_site(site:, country:, provider:, effective_on:) }
  end

  # @param person_id [String]
  # @param fte [Numeric, nil]
  # @param employment_type [String, nil]
  def change_employment(person_id, fte:, employment_type:, provider:, effective_on:)
    @repository.with_person(person_id) do |person|
      person.change_employment(fte:, employment_type:, provider:, effective_on:)
    end
  end
end
