# frozen_string_literal: true

# Event-sourced aggregate for one person in the Org Graph.
#
# One RES stream per person: tenant-{tenant_id}/Person-{person_id}. It holds
# operational facts only, keyed by person id. Identifiers (name, email,
# external id) live on the `people` row and never in an event. Each command
# takes the named facts as keywords, so nothing else from a provider's payload
# can reach an event.
#
# A change that matches what the person already holds writes nothing, so a
# sync that finds no difference leaves the stream untouched.
#
class OrgGraph::PersonAggregate
  include AggregateRoot
  include OrgGraph::FactConfirmation

  PROVIDERS = (HrisConfig::PROVIDERS + %w[espalia]).freeze
  EMPLOYMENT_STATUSES = %w[pending employed left].freeze
  FACT_KEYS = %i[title level manager_id cost_centre site country fte employment_type].freeze
  private_constant :FACT_KEYS
  # The kind of fact each keyword writes, as the provider settings name them
  # ({OrgGraph::StructureAggregate::FACTS}). A keyword missing here would be
  # taken from any provider.
  FACT_KINDS = {
    employment_status: "employment_status", started_on: "employment_status", left_on: "employment_status",
    title: "title", level: "level", manager_id: "manager", cost_centre: "cost_centre",
    site: "site", country: "site", fte: "employment", employment_type: "employment"
  }.freeze

  def initialize
    @person_id = nil
    @employment_status = nil
    @last_status_change = nil
    @started_on = nil
    @left_on = nil
    @left_from = nil
    @facts = {}
    @fact_providers = {}
    @memberships = {}
    @membership_ends = {}
  end

  # Records the person for the first time, with the facts as they stood.
  #
  # @param person_id [String] UUID of the person
  # @param provider [String] one of {PROVIDERS}
  # @param effective_on [Date, String] when these facts were observed
  # @param employment_status [String] one of {EMPLOYMENT_STATUSES}
  # @param started_on [Date, String, nil]
  # @param left_on [Date, String, nil]
  # @param title [String, nil]
  # @param level [String, nil]
  # @param manager_id [String, nil] person_id of their manager
  # @param cost_centre [String, nil]
  # @param site [String, nil]
  # @param country [String, nil]
  # @param fte [Numeric, nil] greater than 0 and at most 1
  # @param employment_type [String, nil]
  # @raise [RuntimeError] if already recorded or a fact is invalid
  def record(person_id, provider:, effective_on:, employment_status:, started_on: nil, left_on: nil,
             title: nil, level: nil, manager_id: nil, cost_centre: nil, site: nil, country: nil,
             fte: nil, employment_type: nil)
    raise "Person already recorded" if recorded?
    raise "Person id can't be blank" if person_id.blank?
    raise "Invalid employment status: #{employment_status}" unless EMPLOYMENT_STATUSES.include?(employment_status)

    started_on = normalize_date(started_on, :started_on)
    left_on = normalize_date(left_on, :left_on)
    raise "A person can't leave before they start" if started_on && left_on && left_on < started_on

    @person_id = person_id
    apply(OrgGraph::Events::PersonRecorded.new(data: provenance(provider, effective_on).merge(
      employment_status: employment_status,
      started_on: started_on,
      left_on: left_on,
      title: label(title),
      level: label(level),
      manager_id: validated_manager(manager_id),
      cost_centre: label(cost_centre),
      site: label(site),
      country: label(country),
      fte: validated_fte(fte),
      employment_type: label(employment_type)
    )))
  end

  # A person who had not yet started has joined.
  #
  # @param provider [String] one of {PROVIDERS}
  # @param effective_on [Date, String] their start date
  # @raise [RuntimeError] unless the person is pending or employed
  def join(provider:, effective_on:)
    move_status(OrgGraph::Events::PersonJoined, to: "employed", from: %w[pending], provider:, effective_on:)
  end

  # A person has left, or a hire who never started has dropped out.
  #
  # @param provider [String] one of {PROVIDERS}
  # @param effective_on [Date, String] their leaving date
  # @raise [RuntimeError] unless the person has been recorded
  def leave(provider:, effective_on:)
    move_status(OrgGraph::Events::PersonLeft, to: "left", from: %w[pending employed], provider:, effective_on:)
  end

  # A person who had left is employed again.
  #
  # @param provider [String] one of {PROVIDERS}
  # @param effective_on [Date, String] their return date
  # @raise [RuntimeError] unless the person has left or is employed
  def return_to_work(provider:, effective_on:)
    move_status(OrgGraph::Events::PersonReturned, to: "employed", from: %w[left], provider:, effective_on:)
  end

  # @param title [String, nil] the new title, or nil for none
  def change_title(title, provider:, effective_on:)
    change(OrgGraph::Events::TitleChanged, provider, effective_on, title: label(title))
  end

  # @param level [String, nil] the provider's level, before any framework mapping
  def change_level(level, provider:, effective_on:)
    change(OrgGraph::Events::LevelChanged, provider, effective_on, level: label(level))
  end

  # @param manager_id [String, nil] person_id of the new manager, or nil for none
  # @raise [RuntimeError] if the person would manage themselves
  def change_manager(manager_id, provider:, effective_on:)
    change(OrgGraph::Events::ManagerChanged, provider, effective_on, manager_id: validated_manager(manager_id))
  end

  # @param cost_centre [String, nil] a label from the provider
  def change_cost_centre(cost_centre, provider:, effective_on:)
    change(OrgGraph::Events::CostCentreChanged, provider, effective_on, cost_centre: label(cost_centre))
  end

  # @param site [String, nil]
  # @param country [String, nil]
  def change_site(site:, country:, provider:, effective_on:)
    change(OrgGraph::Events::SiteChanged, provider, effective_on, site: label(site), country: label(country))
  end

  # @param fte [Numeric, nil] greater than 0 and at most 1
  # @param employment_type [String, nil]
  # @raise [RuntimeError] if fte is out of range
  def change_employment(fte:, employment_type:, provider:, effective_on:)
    change(OrgGraph::Events::EmploymentChanged, provider, effective_on,
      fte: validated_fte(fte), employment_type: label(employment_type))
  end

  # Places the person in a unit, or changes their terms there. Each unit holds
  # one membership per person; the same terms from the same provider write
  # nothing. A hire who has not started yet can be placed ahead of their start.
  # A change may be backdated, but a membership can't start again before the
  # last one in the same unit ended.
  #
  # @param unit_id [String] UUID of a live unit
  # @param allocation [Numeric, nil] greater than 0 and at most 1; nil when unstated
  # @param role [String, nil] the role played in the unit
  # @param provider [String] one of {PROVIDERS}
  # @param effective_on [Date, String]
  # @param set_by_id [String, nil] person_id of the actor
  # @param plan_change_id [String, nil] the plan change it was applied from
  # @param changed_back_id [String, nil] the event this changes back
  # @raise [RuntimeError] if the person has left, a value is invalid, or it
  #   would restart before the last membership ended
  def set_membership(unit_id, provider:, effective_on:, allocation: nil, role: nil, set_by_id: nil, plan_change_id: nil,
                     changed_back_id: nil)
    ensure_recorded!
    raise "A person who has left can't join a unit" if @employment_status == "left"

    unit_id = validated_unit(unit_id)
    data = provenance(provider, effective_on)
    terms = { allocation: validated_fraction(allocation, "Allocation"), role: label(role) }
    current = @memberships[unit_id]
    return if current && current.slice(:allocation, :role, :provider) == terms.merge(provider: provider)

    ended_on = @membership_ends[unit_id]
    if ended_on && data[:effective_on] < ended_on
      raise "A membership can't restart before the last one ended on #{ended_on}"
    end

    apply(OrgGraph::Events::MembershipSet.new(data: data.merge(unit_id: unit_id, **terms,
      set_by_id: set_by_id, plan_change_id: plan_change_id, changed_back_id: changed_back_id)))
  end

  # Ends the person's membership of one unit.
  #
  # @param unit_id [String]
  # @param provider [String] one of {PROVIDERS}
  # @param effective_on [Date, String] the last day of the membership
  # @param ended_by_id [String, nil] person_id of the actor
  # @param plan_change_id [String, nil]
  # @param changed_back_id [String, nil]
  # @raise [RuntimeError] if the person is not a member, or it would end
  #   before the membership's last change
  def end_membership(unit_id, provider:, effective_on:, ended_by_id: nil, plan_change_id: nil, changed_back_id: nil)
    ensure_recorded!
    unit_id = validated_unit(unit_id)
    membership = @memberships[unit_id]
    raise "Not a member of this unit" unless membership

    data = provenance(provider, effective_on)
    if data[:effective_on] < membership[:changed_on]
      raise "A membership can't end before its last change on #{membership[:changed_on]}"
    end

    apply(OrgGraph::Events::MembershipEnded.new(data: data.merge(unit_id: unit_id,
      ended_by_id: ended_by_id, plan_change_id: plan_change_id, changed_back_id: changed_back_id)))
  end

  # Moves the person's membership of one unit to another, keeping its terms
  # and when it began, since the destination carries on from the unit they
  # were in. A person already in the destination keeps that membership, and a
  # person who has left can't join one, so in either case the membership they
  # had ends instead.
  #
  # @param from_unit_id [String] a unit they are a member of
  # @param unit_id [String] the live unit they move to
  # @param effective_on [Date, String]
  # @param moved_by_id [String, nil] person_id of the actor
  # @param plan_change_id [String, nil]
  # @param changed_back_id [String, nil]
  # @raise [RuntimeError] if the person is not a member, or it would move before it began
  def move_membership(from_unit_id, unit_id, effective_on:, moved_by_id: nil, plan_change_id: nil, changed_back_id: nil)
    ensure_recorded!
    from_unit_id = validated_unit(from_unit_id)
    unit_id = validated_unit(unit_id)
    membership = @memberships[from_unit_id]
    raise "Not a member of this unit" unless membership
    raise "A membership can't move to the unit it is in" if from_unit_id == unit_id

    if @memberships.key?(unit_id) || @employment_status == "left"
      return end_membership(from_unit_id, provider: membership[:provider], effective_on:, ended_by_id: moved_by_id,
                                          plan_change_id:, changed_back_id:)
    end

    data = provenance(membership[:provider], effective_on)
    raise "A membership can't move before it begins" if data[:effective_on] < membership[:since]
    if data[:effective_on] < membership[:changed_on]
      raise "A membership can't move before its last change on #{membership[:changed_on]}"
    end
    ended_on = @membership_ends[unit_id]
    if ended_on && data[:effective_on] < ended_on
      raise "A membership can't restart before the last one ended on #{ended_on}"
    end

    apply(OrgGraph::Events::MembershipMoved.new(data: data.merge(from_unit_id: from_unit_id, unit_id: unit_id,
      **membership.slice(:allocation, :role), moved_by_id: moved_by_id, plan_change_id: plan_change_id,
      changed_back_id: changed_back_id)))
  end

  # @param unit_id [String]
  # @return [Date, nil] the latest date a change to this membership took
  #   effect, which a backdated change leaves in place
  def membership_changed_on(unit_id)
    changed_on = @memberships.dig(unit_id.to_s.downcase, :changed_on)
    changed_on && Date.iso8601(changed_on.to_s)
  end

  # @return [Boolean] whether the Org Graph has seen this person yet
  def recorded?
    !@employment_status.nil?
  end

  # Applies the facts a provider supplies, writing one event for each that
  # differs. A fact left out is not compared, so a provider that does not
  # supply a fact never clears it. A person not yet recorded writes nothing,
  # once the facts have been checked.
  #
  # @param provider [String] one of {PROVIDERS}
  # @param effective_on [Date, String]
  # @param facts [Hash] any of :title, :level, :manager_id, :cost_centre,
  #   :site with :country, and :fte with :employment_type
  # @raise [ArgumentError] for a fact it does not name, or half a pair
  def apply_facts(provider:, effective_on:, **facts)
    check_facts!(facts)
    return unless recorded?

    when_given = { provider:, effective_on: }
    change_title(facts[:title], **when_given) if facts.key?(:title)
    change_level(facts[:level], **when_given) if facts.key?(:level)
    change_manager(facts[:manager_id], **when_given) if facts.key?(:manager_id)
    change_cost_centre(facts[:cost_centre], **when_given) if facts.key?(:cost_centre)
    change_site(**pair(facts, :site, :country), **when_given) if facts.key?(:site) || facts.key?(:country)
    change_employment(**pair(facts, :fte, :employment_type), **when_given) if facts.key?(:fte) || facts.key?(:employment_type)
  end

  # Moves a recorded person to the status a provider reports, for a provider
  # that gives the status without a status-change date. One that matches
  # writes nothing, so a repeat sync never moves the date of the last change.
  # A join is effective on the start date and a leaving on the termination
  # date when the provider holds them, else on `effective_on`. A return is
  # effective on the start date only when it falls after the leaving, since
  # a returner's provider may still hold the first start. A leaver whose
  # termination date arrives or changes gets a PersonLeft on that date. A
  # reported `pending` never moves someone back from employed, nor a leaver
  # back before a rehire starts, nor joins a hire whose recorded start is
  # still ahead when the provider sends none.
  #
  # @param employment_status [String] one of {EMPLOYMENT_STATUSES}
  # @param provider [String] one of {PROVIDERS}
  # @param effective_on [Date, String] the sync's date
  # @param started_on [Date, String, nil]
  # @param left_on [Date, String, nil]
  def match_status(employment_status, provider:, effective_on:, started_on: nil, left_on: nil)
    if employment_status == @employment_status
      correct_leaving_date(left_on, provider) if left? && left_on.present?
      return
    end

    case employment_status
    when "pending" then nil
    when "left" then leave(provider:, effective_on: left_on.presence || effective_on)
    when "employed"
      if @employment_status == "pending"
        return if started_on.blank? && @started_on && @started_on > normalize_date(effective_on, :effective_on)

        join(provider:, effective_on: started_on.presence || @started_on || effective_on)
      else
        return_to_work(provider:, effective_on: return_date(started_on) || effective_on)
      end
    else raise "Can't move from #{@employment_status} to #{employment_status}"
    end
  end

  # @return [Boolean] whether the person has left
  def left?
    @employment_status == "left"
  end

  # Supplies or corrects the start date of someone already recorded. Blank or
  # unchanged writes nothing.
  #
  # @param started_on [Date, String, nil]
  # @param provider [String] one of {PROVIDERS}
  def change_start_date(started_on, provider:)
    ensure_recorded!
    started_on = normalize_date(started_on, :started_on)
    return if started_on.nil? || started_on == @started_on

    apply(OrgGraph::Events::StartDateChanged.new(data: provenance(provider, started_on).merge(started_on:)))
  end

  # @param facts [Hash] the keywords {#apply_facts} takes besides provenance
  # @raise [ArgumentError] for a fact it does not name, or half a pair
  def check_facts!(facts)
    unknown = facts.keys - FACT_KEYS
    raise ArgumentError, "Unknown facts: #{unknown.join(", ")}" if unknown.any?
    pair(facts, :site, :country) if facts.key?(:site) || facts.key?(:country)
    pair(facts, :fte, :employment_type) if facts.key?(:fte) || facts.key?(:employment_type)
  end

  private

  def pair(facts, *keys)
    missing = keys - facts.keys
    raise ArgumentError, "#{keys.join(" and ")} travel together; missing #{missing.join(", ")}" if missing.any?

    facts.slice(*keys)
  end

  def ensure_recorded!
    raise "Person not recorded" unless recorded?
  end

  # Already in the target status, the call writes nothing, unless it repeats the
  # last status event with a different date or provider: a corrected date or a
  # handover, written as a new event rather than lost.
  def move_status(event_class, to:, from:, provider:, effective_on:)
    ensure_recorded!
    data = provenance(provider, effective_on)

    if @employment_status == to
      return unless @last_status_change&.first == event_class
      return if @last_status_change.last == data.values_at(:effective_on, :provider)
    elsif !from.include?(@employment_status)
      raise "Can't move from #{@employment_status} to #{to}"
    end
    ensure_leaves_after_start!(data[:effective_on]) if to == "left"

    apply(event_class.new(data: data))
  end

  def correct_leaving_date(left_on, provider)
    data = provenance(provider, left_on)
    return if data[:effective_on] == @left_on

    ensure_leaves_after_start!(data[:effective_on])
    apply(OrgGraph::Events::PersonLeft.new(data: data))
  end

  def return_date(started_on)
    started_on = normalize_date(started_on, :started_on)
    started_on if started_on && @left_on && started_on > @left_on
  end

  # A hire who never started may drop out at any date, before or after a correction.
  def ensure_leaves_after_start!(left_on)
    had_started = @employment_status == "employed" || @left_from == "employed"
    raise "A person can't leave before they start" if had_started && @started_on && left_on < @started_on
  end

  # A value the person already holds, from the same provider, writes nothing.
  # The effective date is not compared: a sync dates every comparison today.
  def change(event_class, provider, effective_on, **facts)
    ensure_recorded!
    data = provenance(provider, effective_on)
    return if facts.all? { |key, value| @facts[key] == value && @fact_providers[key] == provider }

    apply(event_class.new(data: data.merge(facts)))
  end

  def provenance(provider, effective_on)
    raise "Unknown provider: #{provider}" unless PROVIDERS.include?(provider)

    effective = normalize_date(effective_on, :effective_on)
    raise "Effective date can't be blank" if effective.nil?

    { person_id: @person_id, provider: provider, effective_on: effective }
  end

  def normalize_date(value, name)
    return nil if value.blank?

    (value.is_a?(String) ? Date.iso8601(value) : value.to_date).iso8601
  rescue Date::Error, NoMethodError
    raise "Invalid #{name}: #{value}"
  end

  def label(value)
    value.to_s.strip.presence
  end

  def validated_manager(manager_id)
    manager_id = manager_id.presence
    raise "A person can't manage themselves" if manager_id && manager_id == @person_id

    manager_id
  end

  def validated_fte(fte)
    validated_fraction(fte, "FTE")
  end

  def validated_fraction(value, name)
    return nil if value.blank?

    fraction = Float(value)
    raise "#{name} must be greater than 0 and at most 1: #{value}" unless fraction.positive? && fraction <= 1

    fraction
  rescue ArgumentError, TypeError
    raise "Invalid #{name}: #{value}"
  end

  def validated_unit(unit_id)
    raise "Unit id must be a UUID: #{unit_id}" unless OrgGraph::StructureAggregate::UUID.match?(unit_id.to_s)

    unit_id.to_s.downcase
  end

  # ── Event handlers ──

  on OrgGraph::Events::PersonRecorded do |event|
    @person_id = event.data[:person_id]
    @employment_status = event.data[:employment_status]
    @started_on = event.data[:started_on]
    @left_on = event.data[:left_on]
    @facts = event.data.slice(*FACT_KEYS)
    @fact_providers = FACT_KEYS.index_with(event.data[:provider])
  end

  {
    OrgGraph::Events::PersonJoined => "employed",
    OrgGraph::Events::PersonLeft => "left",
    OrgGraph::Events::PersonReturned => "employed"
  }.each do |event_class, status|
    on event_class do |event|
      @left_from = @employment_status if event_class == OrgGraph::Events::PersonLeft && @employment_status != "left"
      @employment_status = status
      @last_status_change = [ event_class, event.data.values_at(:effective_on, :provider) ]
      @started_on = event.data[:effective_on] if event_class == OrgGraph::Events::PersonJoined
      @left_on = event.data[:effective_on] if event_class == OrgGraph::Events::PersonLeft
    end
  end

  [
    OrgGraph::Events::TitleChanged, OrgGraph::Events::LevelChanged, OrgGraph::Events::ManagerChanged,
    OrgGraph::Events::CostCentreChanged, OrgGraph::Events::SiteChanged, OrgGraph::Events::EmploymentChanged
  ].each do |event_class|
    on event_class do |event|
      changed = event.data.slice(*FACT_KEYS)
      @facts.merge!(changed)
      @fact_providers.merge!(changed.keys.index_with(event.data[:provider]))
    end
  end

  on OrgGraph::Events::StartDateChanged do |event|
    @started_on = event.data[:started_on]
  end

  on OrgGraph::Events::MembershipSet do |event|
    data = event.data
    current = @memberships[data[:unit_id]] || {}
    @memberships[data[:unit_id]] = data.slice(:allocation, :role, :provider).merge(
      since: [ current[:since], data[:effective_on] ].compact.min,
      changed_on: [ current[:changed_on], data[:effective_on] ].compact.max
    )
  end

  on OrgGraph::Events::MembershipEnded do |event|
    @memberships.delete(event.data[:unit_id])
    @membership_ends[event.data[:unit_id]] = event.data[:effective_on]
  end

  on OrgGraph::Events::MembershipMoved do |event|
    data = event.data
    since = @memberships.delete(data[:from_unit_id])&.fetch(:since) || data[:effective_on]
    @membership_ends[data[:from_unit_id]] = data[:effective_on]
    @memberships[data[:unit_id]] = data.slice(:allocation, :role, :provider).merge(since: since, changed_on: data[:effective_on])
  end
end
