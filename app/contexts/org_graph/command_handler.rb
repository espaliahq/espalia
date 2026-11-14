# frozen_string_literal: true

# Handles commands for Org Graph person aggregates.
#
# Each method loads the person's stream, runs the command, and stores the
# resulting events. Every command names its provider and effective date, and
# is refused unless that provider supplies what it changes: a fact's provider
# is the tenant's setting for its kind, for people who carry that provider's
# external id, and Espalia for anyone else; a membership's is its unit's own.
#
# Each handler names its actor and refuses what {OrgGraphPolicy} doesn't let
# that actor change. See {OrgGraph::Authorization}.
#
# Every command also takes `plan_id:` and `plan_change_id:`, the plan change
# it was applied from, and writes them on each event. See {OrgGraph::PlanReference}.
#
class OrgGraph::CommandHandler
  include OrgGraph::Authorization

  # @param actor [AuthorizationContext, Object] who is acting, checked against
  #   {OrgGraphPolicy}, or {OrgGraph::Authorization::SYSTEM}, which is not
  # @param cause_id [String, nil] shared by every event this handler writes,
  #   as their correlation id: a plan's approval, say. Without one, events
  #   keep the request's.
  # @param repository [OrgGraph::Repository]
  # @raise [ArgumentError] without an actor
  def initialize(actor:, cause_id: nil, repository: OrgGraph::Repository.new)
    @actor = actor!(actor)
    @cause_id = cause_id
    @repository = repository
  end

  # Records a person the Org Graph has not seen before.
  #
  # @param person_id [String] UUID of the person
  # @param facts [Hash] keywords accepted by {OrgGraph::PersonAggregate#record}
  def record_person(person_id, **facts)
    plan, facts = OrgGraph::PlanReference.extract(facts)
    authorize_structure!
    ensure_provides!(person_id, facts[:provider], *facts.keys)
    with_person(person_id, plan) { |person| person.record(person_id, **facts) }
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
    plan, facts = OrgGraph::PlanReference.extract(facts)
    authorize_structure!
    ensure_provides!(person_id, provider, *facts.keys)
    written = 0
    with_person(person_id, plan) do |person|
      person.apply_facts(provider:, effective_on:, **facts)
      written = person.unpublished_events.count
    end
    written
  end

  # What a provider's sync calls for each person it returns, in one load of
  # their stream: the first time, it records them with the facts as they
  # stand; after that, it supplies or corrects their start date, moves their
  # status if it differs, then applies each fact that differs. A returner's
  # start date waits until they are back. A leaver's
  # facts are not compared, even while a rehire waits for their start date,
  # so who holds them can't refuse a leaving.
  # A leaving date before the start date contradicts it and is dropped.
  #
  # @param person_id [String]
  # @param provider [String]
  # @param effective_on [Date, String] the sync's date
  # @param employment_status [String] "pending", "employed" or "left"
  # @param started_on [Date, String, nil] the start date the provider holds
  # @param left_on [Date, String, nil] the leaving date the provider holds
  # @param left_on_source [String, nil] where a leaving date worked out from
  #   the person's row came from; kept only when they are first recorded
  # @param facts [Hash] keywords accepted by {OrgGraph::PersonAggregate#apply_facts}
  # @return [Integer] how many events were written
  def sync_person(person_id, provider:, effective_on:, employment_status:, started_on: nil, left_on: nil, left_on_source: nil, **facts)
    plan, facts = OrgGraph::PlanReference.extract(facts)
    authorize_structure!
    ensure_provides!(person_id, provider, :employment_status)
    written = 0
    left_on = nil if leaves_before_start?(left_on, started_on)
    with_person(person_id, plan) do |person|
      person.check_facts!(facts)
      if person.recorded?
        was_left = person.left?
        person.change_start_date(started_on, provider:) unless was_left
        person.match_status(employment_status, provider:, effective_on:, started_on:, left_on:)
        unless person.left?
          ensure_provides!(person_id, provider, *facts.keys)
          person.change_start_date(started_on, provider:) if was_left
          person.apply_facts(provider:, effective_on:, **facts)
        end
      else
        ensure_provides!(person_id, provider, *facts.keys)
        left_on = nil unless employment_status == "left"
        left_on_source = nil unless left_on
        person.record(person_id, provider:, effective_on:, employment_status:, started_on:, left_on:, left_on_source:, **facts)
      end
      written = person.unpublished_events.count
    end
    written
  end

  # @param person_id [String]
  # @param provider [String]
  # @param effective_on [Date, String] their start date
  def join(person_id, provider:, effective_on:, **plan)
    authorize_structure!
    ensure_provides!(person_id, provider, :employment_status)
    with_person(person_id, OrgGraph::PlanReference.new(**plan)) { |person| person.join(provider:, effective_on:) }
  end

  # @param person_id [String]
  # @param provider [String]
  # @param effective_on [Date, String] their leaving date
  def leave(person_id, provider:, effective_on:, **plan)
    authorize_structure!
    ensure_provides!(person_id, provider, :employment_status)
    with_person(person_id, OrgGraph::PlanReference.new(**plan)) { |person| person.leave(provider:, effective_on:) }
  end

  # What a provider's sync calls for a person it no longer returns; see
  # {OrgGraph::PersonAggregate#leave_when_absent}. Refused only when it would
  # write, so a historic leaver doesn't fail every sync once Espalia holds status.
  #
  # @param person_id [String]
  # @param provider [String]
  # @param effective_on [Date, String] the sync's date
  # @return [Integer] how many events were written
  def record_absence(person_id, provider:, effective_on:)
    authorize_structure!
    written = 0
    @repository.with_person(person_id) do |person|
      person.leave_when_absent(provider:, effective_on:)
      written = person.unpublished_events.count
      ensure_provides!(person_id, provider, :employment_status) if written.positive?
    end
    written
  end

  # Records that a leaver's identifiers were erased. Only {OrgGraph::Forgetting}
  # calls this, as the system, inside the transaction that erases them, once
  # it has checked {TenantPolicy#forget_person?} for whoever asked.
  #
  # @param person_id [String]
  # @param options [Hash] keywords accepted by {OrgGraph::PersonAggregate#forget}
  # @raise [OrgGraph::Authorization::Refused] for any actor but the system
  def forget_person(person_id, **options)
    raise Refused, "Only the forgetting step can forget a person" unless system?

    @repository.with_person(person_id, cause_id: @cause_id) { |person| person.forget(**options) }
  end

  # @param person_id [String]
  # @param provider [String]
  # @param effective_on [Date, String] their return date
  def return_to_work(person_id, provider:, effective_on:, **plan)
    authorize_structure!
    ensure_provides!(person_id, provider, :employment_status)
    with_person(person_id, OrgGraph::PlanReference.new(**plan)) { |person| person.return_to_work(provider:, effective_on:) }
  end

  # @param person_id [String]
  # @param title [String, nil]
  def change_title(person_id, title, provider:, effective_on:, **plan)
    authorize_structure!
    ensure_provides!(person_id, provider, :title)
    with_person(person_id, OrgGraph::PlanReference.new(**plan)) { |person| person.change_title(title, provider:, effective_on:) }
  end

  # @param person_id [String]
  # @param level [String, nil] the provider's level, before any framework mapping
  def change_level(person_id, level, provider:, effective_on:, **plan)
    authorize_structure!
    ensure_provides!(person_id, provider, :level)
    with_person(person_id, OrgGraph::PlanReference.new(**plan)) { |person| person.change_level(level, provider:, effective_on:) }
  end

  # @param person_id [String]
  # @param manager_id [String, nil] person_id of the new manager, or nil for none
  def change_manager(person_id, manager_id, provider:, effective_on:, **plan)
    authorize_structure!
    ensure_provides!(person_id, provider, :manager_id)
    with_person(person_id, OrgGraph::PlanReference.new(**plan)) { |person| person.change_manager(manager_id, provider:, effective_on:) }
  end

  # @param person_id [String]
  # @param cost_centre [String, nil]
  def change_cost_centre(person_id, cost_centre, provider:, effective_on:, **plan)
    authorize_structure!
    ensure_provides!(person_id, provider, :cost_centre)
    with_person(person_id, OrgGraph::PlanReference.new(**plan)) { |person| person.change_cost_centre(cost_centre, provider:, effective_on:) }
  end

  # @param person_id [String]
  # @param site [String, nil]
  # @param country [String, nil]
  def change_site(person_id, site:, country:, provider:, effective_on:, **plan)
    authorize_structure!
    ensure_provides!(person_id, provider, :site)
    with_person(person_id, OrgGraph::PlanReference.new(**plan)) { |person| person.change_site(site:, country:, provider:, effective_on:) }
  end

  # @param person_id [String]
  # @param fte [Numeric, nil]
  # @param employment_type [String, nil]
  def change_employment(person_id, fte:, employment_type:, provider:, effective_on:, **plan)
    authorize_structure!
    ensure_provides!(person_id, provider, :fte)
    with_person(person_id, OrgGraph::PlanReference.new(**plan)) do |person|
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
    plan, options = OrgGraph::PlanReference.extract(options)
    authorize_membership!(person_id, unit_id)
    unit = ensure_live_unit!(unit_id)
    with_person(person_id, plan) do |person|
      ensure_provides_unit!(unit, options[:provider], person_id, held: person.membership_provider(unit.id))
      person.set_membership(unit_id, **attributed(options, :set_by_id))
    end
  end

  # Ends a person's membership of one unit. A retired unit's memberships can
  # still be ended; a unit the structure doesn't hold can't be checked, so is refused.
  #
  # @param person_id [String]
  # @param unit_id [String]
  # @param options [Hash] keywords accepted by {OrgGraph::PersonAggregate#end_membership}
  def end_membership(person_id, unit_id, **options)
    plan, options = OrgGraph::PlanReference.extract(options)
    authorize_membership!(person_id, unit_id)
    unit = find_unit(unit_id) or raise "Unit not found"
    with_person(person_id, plan) do |person|
      ensure_provides_unit!(unit, options[:provider], person_id, held: person.membership_provider(unit.id))
      person.end_membership(unit_id, **attributed(options, :ended_by_id))
    end
  end

  # Ends every open membership a person has, as the system does when they
  # leave. See {OrgGraph::PersonAggregate#end_memberships}.
  #
  # @param person_id [String]
  # @param effective_on [Date, String]
  def end_memberships(person_id, effective_on:, **plan)
    authorize_structure!
    with_person(person_id, OrgGraph::PlanReference.new(**plan)) { |person| person.end_memberships(effective_on:) }
  end

  # Moves a person's membership to a live unit, keeping its terms.
  #
  # @param person_id [String]
  # @param from_unit_id [String]
  # @param unit_id [String] a live unit in the tenant's structure
  # @param options [Hash] keywords accepted by {OrgGraph::PersonAggregate#move_membership}
  # @raise [RuntimeError] if the destination does not exist or is retired, or
  #   another provider supplies it than the one that supplied the membership
  def move_membership(person_id, from_unit_id, unit_id, **options)
    plan, options = OrgGraph::PlanReference.extract(options)
    authorize_move_membership!(person_id, from_unit_id, unit_id)
    unit = ensure_live_unit!(unit_id)
    from = find_unit(from_unit_id) or raise "Unit not found"
    with_person(person_id, plan) do |person|
      provider = person.membership_provider(from.id) or raise "Not a member of this unit"
      ensure_provides_unit!(unit, provider, person_id, held: (provider if from.provider == unit.provider))
      person.move_membership(from_unit_id, unit_id, **attributed(options, :moved_by_id))
    end
  end

  # Records that a fact Espalia holds about a person is still true. A
  # membership is confirmed only in a live unit, by whoever may change it; any
  # other fact by whoever may change people's facts.
  #
  # @param person_id [String]
  # @param fact [String, Symbol]
  # @param options [Hash] keywords accepted by {OrgGraph::FactConfirmation#confirm_fact}
  # @raise [RuntimeError] if another provider supplies the fact or the unit
  def confirm_fact(person_id, fact, **options)
    plan, options = OrgGraph::PlanReference.extract(options)
    membership = fact.to_s == OrgGraph::FactConfirmation::MEMBERSHIP
    if membership
      authorize_membership!(person_id, options[:unit_id])
      unit = ensure_live_unit!(options[:unit_id])
    else
      authorize_structure!
      ensure_provides!(person_id, OrgGraph::StructureAggregate::ESPALIA, fact.to_sym)
    end
    with_person(person_id, plan) do |person|
      if membership
        ensure_provides_unit!(unit, OrgGraph::StructureAggregate::ESPALIA, person_id, held: person.membership_provider(unit.id))
      end
      person.confirm_fact(fact, **attributed(options, :confirmed_by_id))
    end
  end

  private

  def with_person(person_id, plan, &block)
    @repository.with_person(person_id, plan:, cause_id: @cause_id, &block)
  end

  def leaves_before_start?(left_on, started_on)
    left_on.present? && started_on.present? && left_on.to_date < started_on.to_date
  rescue Date::Error, NoMethodError
    false
  end

  # Reads the structure projection, which is written synchronously with the
  # structure stream, rather than replaying that stream for every person.
  def ensure_live_unit!(unit_id)
    unit = find_unit(unit_id)
    raise "Unit not found" unless unit
    raise "Unit is retired" if unit.retired?

    unit
  end

  # Reads the fact providers the structure projection writes, as above. A
  # provider holds a fact only for people who carry its external id: anyone
  # else, added by hand or with an account, is Espalia's for every fact.
  def ensure_provides!(person_id, provider, *keys)
    kinds = keys.filter_map { |key| OrgGraph::PersonAggregate::FACT_KINDS[key] }.uniq
    return if kinds.empty?

    source = Person.where(id: person_id).where.not(external_id: nil).pick(:hris_source)
    kinds.each do |kind|
      holder = OrgFactProvider.provider_for(kind)
      holder = OrgGraph::StructureAggregate::ESPALIA unless holder == source
      raise "#{holder} supplies #{kind}; change it there" unless holder == provider.to_s
    end
  end

  def find_unit(unit_id)
    OrgUnit.find_by(id: unit_id.to_s.downcase)
  end

  # A unit keeps the provider it was created with, which was its level's then,
  # so a retired unit's members can still be ended after its level changes hands.
  # Espalia may place a person the unit's provider does not know, since its
  # sync will never place them; that membership stays Espalia's, and Espalia
  # can still end or move it once the provider comes to know them.
  #
  # `held` is who supplies the membership as the person's stream has it,
  # never org_memberships, which a Members rebuild empties while writes go on (#170).
  def ensure_provides_unit!(unit, provider, person_id, held:)
    return if unit.provider == provider.to_s
    return if provider.to_s == OrgGraph::StructureAggregate::ESPALIA &&
              (held == provider.to_s || !known_to?(unit.provider, person_id))

    raise "#{unit.provider} supplies this unit; change its members there"
  end

  def known_to?(provider, person_id)
    Person.where(id: person_id, hris_source: provider).where.not(external_id: nil).exists?
  end
end
