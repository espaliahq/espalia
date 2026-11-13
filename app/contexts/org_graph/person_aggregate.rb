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

  PROVIDERS = (HrisConfig::PROVIDERS + %w[espalia]).freeze
  EMPLOYMENT_STATUSES = %w[pending employed left].freeze
  FACT_KEYS = %i[title level manager_id cost_centre site country fte employment_type].freeze
  private_constant :FACT_KEYS

  def initialize
    @person_id = nil
    @employment_status = nil
    @facts = {}
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

    @person_id = person_id
    apply(OrgGraph::Events::PersonRecorded.new(data: provenance(provider, effective_on).merge(
      employment_status: employment_status,
      started_on: normalize_date(started_on, :started_on),
      left_on: normalize_date(left_on, :left_on),
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

  # A person who had not yet started has joined. No-op if already employed.
  #
  # @param provider [String] one of {PROVIDERS}
  # @param effective_on [Date, String] their start date
  # @raise [RuntimeError] unless the person is pending or employed
  def join(provider:, effective_on:)
    ensure_recorded!
    data = provenance(provider, effective_on)
    return if transition!(from: "pending", to: "employed")

    apply(OrgGraph::Events::PersonJoined.new(data: data))
  end

  # A person has left. No-op if already left.
  #
  # @param provider [String] one of {PROVIDERS}
  # @param effective_on [Date, String] their leaving date
  # @raise [RuntimeError] unless the person is employed or left
  def leave(provider:, effective_on:)
    ensure_recorded!
    data = provenance(provider, effective_on)
    return if transition!(from: "employed", to: "left")

    apply(OrgGraph::Events::PersonLeft.new(data: data))
  end

  # A person who had left is employed again. No-op if already employed.
  #
  # @param provider [String] one of {PROVIDERS}
  # @param effective_on [Date, String] their return date
  # @raise [RuntimeError] unless the person has left or is employed
  def return_to_work(provider:, effective_on:)
    ensure_recorded!
    data = provenance(provider, effective_on)
    return if transition!(from: "left", to: "employed")

    apply(OrgGraph::Events::PersonReturned.new(data: data))
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

  private

  def recorded?
    !@employment_status.nil?
  end

  def ensure_recorded!
    raise "Person not recorded" unless recorded?
  end

  # Returns true when the person is already in the target status (nothing to
  # write), false when the move is allowed, and raises otherwise.
  def transition!(from:, to:)
    return true if @employment_status == to
    raise "Can't move from #{@employment_status} to #{to}" unless @employment_status == from

    false
  end

  def change(event_class, provider, effective_on, **facts)
    ensure_recorded!
    data = provenance(provider, effective_on)
    return if facts.all? { |key, value| @facts[key] == value }

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

    (value.is_a?(Date) ? value : Date.iso8601(value.to_s)).iso8601
  rescue Date::Error
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
    return nil if fte.nil?

    value = Float(fte)
    raise "FTE must be greater than 0 and at most 1: #{fte}" unless value.positive? && value <= 1

    value
  rescue ArgumentError, TypeError
    raise "Invalid FTE: #{fte}"
  end

  # ── Event handlers ──

  on OrgGraph::Events::PersonRecorded do |event|
    @person_id = event.data[:person_id]
    @employment_status = event.data[:employment_status]
    @facts = event.data.slice(*FACT_KEYS)
  end

  on OrgGraph::Events::PersonJoined do |_event|
    @employment_status = "employed"
  end

  on OrgGraph::Events::PersonLeft do |_event|
    @employment_status = "left"
  end

  on OrgGraph::Events::PersonReturned do |_event|
    @employment_status = "employed"
  end

  [
    OrgGraph::Events::TitleChanged, OrgGraph::Events::LevelChanged, OrgGraph::Events::ManagerChanged,
    OrgGraph::Events::CostCentreChanged, OrgGraph::Events::SiteChanged, OrgGraph::Events::EmploymentChanged
  ].each do |event_class|
    on event_class do |event|
      @facts.merge!(event.data.slice(*FACT_KEYS))
    end
  end
end
