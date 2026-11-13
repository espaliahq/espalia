# frozen_string_literal: true

# Handles commands for Org Graph person aggregates.
#
# Each method loads the person's stream, runs the command, and stores the
# resulting events. Every command names its provider and effective date, and
# is refused unless that provider supplies what it changes: a fact's provider
# is the tenant's setting for its kind, a membership's is its unit's own.
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
    ensure_provides!(facts[:provider], *facts.keys)
    @repository.with_person(person_id) { |person| person.record(person_id, **facts) }
  end

  # Applies the facts a provider supplies for one person in one load of their
  # stream. A person the Org Graph has not recorded yet is left alone: the
  # first sync records them (story 1.3).
  #
  # @param person_id [String]
  # @param provider [String]
  # @param effective_on [Date, String]
  # @param facts [Hash] keywords accepted by {OrgGraph::PersonAggregate#apply_facts}
  # @return [Integer] how many events were written
  def apply_facts(person_id, provider:, effective_on:, **facts)
    ensure_provides!(provider, *facts.keys)
    written = 0
    @repository.with_person(person_id) do |person|
      person.apply_facts(provider:, effective_on:, **facts)
      written = person.unpublished_events.count
    end
    written
  end

  # What a provider's sync calls for each person it returns, in one load of
  # their stream: the first time, it records them with the facts as they
  # stand; after that, it moves their status if it differs and applies each
  # fact that differs. A leaver's facts are not compared.
  #
  # @param person_id [String]
  # @param provider [String]
  # @param effective_on [Date, String]
  # @param employment_status [String] "employed" or "left"
  # @param facts [Hash] keywords accepted by {OrgGraph::PersonAggregate#apply_facts}
  # @return [Integer] how many events were written
  def sync_person(person_id, provider:, effective_on:, employment_status:, **facts)
    ensure_provides!(provider, :employment_status, *facts.keys)
    written = 0
    @repository.with_person(person_id) do |person|
      person.check_facts!(facts)
      if person.recorded?
        person.match_status(employment_status, provider:, effective_on:)
        person.apply_facts(provider:, effective_on:, **facts) unless employment_status == "left"
      else
        person.record(person_id, provider:, effective_on:, employment_status:, **facts)
      end
      written = person.unpublished_events.count
    end
    written
  end

  # @param person_id [String]
  # @param provider [String]
  # @param effective_on [Date, String] their start date
  def join(person_id, provider:, effective_on:)
    ensure_provides!(provider, :employment_status)
    @repository.with_person(person_id) { |person| person.join(provider:, effective_on:) }
  end

  # @param person_id [String]
  # @param provider [String]
  # @param effective_on [Date, String] their leaving date
  def leave(person_id, provider:, effective_on:)
    ensure_provides!(provider, :employment_status)
    @repository.with_person(person_id) { |person| person.leave(provider:, effective_on:) }
  end

  # @param person_id [String]
  # @param provider [String]
  # @param effective_on [Date, String] their return date
  def return_to_work(person_id, provider:, effective_on:)
    ensure_provides!(provider, :employment_status)
    @repository.with_person(person_id) { |person| person.return_to_work(provider:, effective_on:) }
  end

  # @param person_id [String]
  # @param title [String, nil]
  def change_title(person_id, title, provider:, effective_on:)
    ensure_provides!(provider, :title)
    @repository.with_person(person_id) { |person| person.change_title(title, provider:, effective_on:) }
  end

  # @param person_id [String]
  # @param level [String, nil] the provider's level, before any framework mapping
  def change_level(person_id, level, provider:, effective_on:)
    ensure_provides!(provider, :level)
    @repository.with_person(person_id) { |person| person.change_level(level, provider:, effective_on:) }
  end

  # @param person_id [String]
  # @param manager_id [String, nil] person_id of the new manager, or nil for none
  def change_manager(person_id, manager_id, provider:, effective_on:)
    ensure_provides!(provider, :manager_id)
    @repository.with_person(person_id) { |person| person.change_manager(manager_id, provider:, effective_on:) }
  end

  # @param person_id [String]
  # @param cost_centre [String, nil]
  def change_cost_centre(person_id, cost_centre, provider:, effective_on:)
    ensure_provides!(provider, :cost_centre)
    @repository.with_person(person_id) { |person| person.change_cost_centre(cost_centre, provider:, effective_on:) }
  end

  # @param person_id [String]
  # @param site [String, nil]
  # @param country [String, nil]
  def change_site(person_id, site:, country:, provider:, effective_on:)
    ensure_provides!(provider, :site)
    @repository.with_person(person_id) { |person| person.change_site(site:, country:, provider:, effective_on:) }
  end

  # @param person_id [String]
  # @param fte [Numeric, nil]
  # @param employment_type [String, nil]
  def change_employment(person_id, fte:, employment_type:, provider:, effective_on:)
    ensure_provides!(provider, :fte)
    @repository.with_person(person_id) do |person|
      person.change_employment(fte:, employment_type:, provider:, effective_on:)
    end
  end

  # Places a person in a live unit, or changes their terms there.
  #
  # @param person_id [String]
  # @param unit_id [String] a live unit in the tenant's structure
  # @param options [Hash] keywords accepted by {OrgGraph::PersonAggregate#set_membership}
  # @raise [RuntimeError] if the unit does not exist or is retired, or another
  #   provider supplies it
  def set_membership(person_id, unit_id, **options)
    ensure_provides_unit!(ensure_live_unit!(unit_id), options[:provider])
    @repository.with_person(person_id) { |person| person.set_membership(unit_id, **options) }
  end

  # Ends a person's membership of one unit. A retired unit's memberships can
  # still be ended.
  #
  # @param person_id [String]
  # @param unit_id [String]
  # @param options [Hash] keywords accepted by {OrgGraph::PersonAggregate#end_membership}
  def end_membership(person_id, unit_id, **options)
    unit = find_unit(unit_id)
    ensure_provides_unit!(unit, options[:provider]) if unit
    @repository.with_person(person_id) { |person| person.end_membership(unit_id, **options) }
  end

  private

  # Reads the structure projection, which is written synchronously with the
  # structure stream, rather than replaying that stream for every person.
  def ensure_live_unit!(unit_id)
    unit = find_unit(unit_id)
    raise "Unit not found" unless unit
    raise "Unit is retired" if unit.retired?

    unit
  end

  # Reads the fact providers the structure projection writes, as above.
  def ensure_provides!(provider, *keys)
    keys.filter_map { |key| OrgGraph::PersonAggregate::FACT_KINDS[key] }.uniq.each do |kind|
      holder = OrgFactProvider.provider_for(kind)
      raise "#{holder} supplies #{kind}; change it there" unless holder == provider.to_s
    end
  end

  def find_unit(unit_id)
    OrgUnit.find_by(id: unit_id.to_s.downcase)
  end

  # A unit keeps the provider it was created with, which was its level's then,
  # so a retired unit's members can still be ended after its level changes hands.
  def ensure_provides_unit!(unit, provider)
    raise "#{unit.provider} supplies this unit; change its members there" unless unit.provider == provider.to_s
  end
end
