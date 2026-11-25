# frozen_string_literal: true

# Event-sourced aggregate for the figures a tenant's plans are priced from:
# pay bands, exchange rates, the reference currency, budget lines and rule
# defaults.
#
# One RES stream per tenant: tenant-{tenant_id}/TenantPlanningInputs. It
# holds every row of the five tables, and the rules that span rows: one band
# per matcher, where a new band lands in the list, a reorder that names every
# band in an order that still stands, and one rate per pair and date. A rule
# about one row alone stays a validation on its model, which the command
# runs first. A row recorded as already held is never refused: the table was
# the truth.
#
class TenantPlanningInputs::Aggregate
  include Shreddable::AggregateRoot

  Events = TenantPlanningInputs::Events

  # The events that write a row, by table: from a command, and from reconcile.
  WRITES = {
    pay_bands: { add: Events::PayBandAdded, change: Events::PayBandChanged, remove: Events::PayBandRemoved },
    exchange_rates: { add: Events::ExchangeRateSet, change: Events::ExchangeRateSet, remove: Events::ExchangeRateRemoved },
    reference_currencies: { add: Events::ReferenceCurrencySet, change: Events::ReferenceCurrencySet, remove: nil },
    budget_lines: { add: Events::BudgetLineAdded, change: Events::BudgetLineChanged, remove: Events::BudgetLineRemoved },
    planning_rule_defaults: { add: Events::PlanningRuleDefaultSet, change: Events::PlanningRuleDefaultSet,
                              remove: Events::PlanningRuleDefaultCleared }
  }.freeze

  BAND_EVENTS = [ Events::PayBandAdded, Events::PayBandChanged, Events::PayBandRemoved, Events::PayBandsReordered ].freeze

  # One row as the stream holds it.
  Entry = Data.define(:row, :created_at, :updated_at, :updated_by_person_id)

  # @return [String, nil] ISO 8601 time the bands last changed, nil until a band event
  attr_reader :bands_changed_at

  def initialize
    @entries = WRITES.keys.index_with { {} }
    @bands_changed_at = nil
  end

  # @param table [Symbol] one of {TenantPlanningInputs::Rows::TABLES}
  # @return [Hash{String => Entry}] by row id
  def entries(table) = @entries.fetch(table)

  # @return [Array<String>] the band ids, position 1 first
  def band_order = entries(:pay_bands).sort_by { |id, entry| [ entry.row["position"], id ] }.map(&:first)

  # Writes a row a command built and validated.
  #
  # @param table [Symbol]
  # @param id [String]
  # @param row [Hash{String => Object}] from {TenantPlanningInputs::Rows.dump}
  # @param at [String] ISO 8601 time, to the microsecond
  # @param changed_by_id [String, nil] person_id of the actor
  # @raise [TenantPlanningInputs::Refused] for a row another row rules out
  def set(table, id:, row:, at:, changed_by_id:)
    held = entries(table).key?(id)
    data = { id:, row:, at:, changed_by_id:, already_held: false }
    case table
    when :pay_bands then data.merge!(band_data(id, row, held, at))
    when :exchange_rates then refuse_second_rate(id, row)
    when :reference_currencies then data[:previous_currency] = entries(table).values.first&.row&.fetch("currency")
    when :planning_rule_defaults then refuse_second_rule(id, row)
    end
    apply(WRITES.fetch(table).fetch(held ? :change : :add).new(data:))
  end

  # @param table [Symbol]
  # @param id [String]
  # @raise [TenantPlanningInputs::Refused] when the stream holds no such row
  def held!(table, id)
    raise TenantPlanningInputs::Refused, "There is no such #{NOUNS.fetch(table)}" unless entries(table).key?(id)
  end

  # @param table [Symbol] any but :reference_currencies, which is only ever set
  # @param id [String]
  # @param at [String]
  # @param changed_by_id [String, nil]
  # @raise [TenantPlanningInputs::Refused] when the stream holds no such row
  def remove(table, id:, at:, changed_by_id:)
    held!(table, id)
    data = { id:, at:, changed_by_id: }
    data.merge!(order: band_order - [ id ], bands_changed_at: at) if table == :pay_bands
    apply(WRITES.fetch(table).fetch(:remove).new(data:))
  end

  # @param ids [Array<String>] every band id once, position 1 first
  # @param from [Array<String>, nil] the order the caller read
  # @param at [String]
  # @param changed_by_id [String, nil]
  # @raise [TenantPlanningInputs::Refused] unless ids are every band once, in a list that hasn't moved since from
  def reorder_bands(ids, from:, at:, changed_by_id:)
    order = band_order
    raise TenantPlanningInputs::Refused, "List every pay band once, as tenants_pay_bands lists them" unless ids.sort == order.sort
    raise TenantPlanningInputs::Refused, "The list has changed since you read it: read tenants_pay_bands again" if from && from != order

    apply(Events::PayBandsReordered.new(data: { order: ids, at:, changed_by_id:, bands_changed_at: at }))
  end

  # Records a row the table holds and the stream doesn't, as it stands.
  #
  # @param table [Symbol]
  # @param id [String]
  # @param row [Hash{String => Object}]
  # @param created_at [String]
  # @param updated_at [String]
  # @param last_changed_by_id [String, nil] the person linked to the row's editor
  # @param bands_changed_at [String, nil] the tenant's stamp, for a band
  def record_held(table, id:, row:, created_at:, updated_at:, last_changed_by_id:, bands_changed_at: nil)
    event = WRITES.fetch(table).fetch(entries(table).key?(id) ? :change : :add)
    apply(event.new(data: held_data(table, id:, row:, at: updated_at, last_changed_by_id:, bands_changed_at:)
                            .merge(created_at:)))
  end

  # Records a row the table changed in place, as it stands now.
  #
  # @param (see #record_held)
  def record_changed(table, id:, row:, updated_at:, last_changed_by_id:, bands_changed_at: nil)
    apply(WRITES.fetch(table).fetch(:change).new(data: held_data(table, id:, row:, at: updated_at, last_changed_by_id:,
                                                                         bands_changed_at:)))
  end

  # Records a row the stream holds and the table doesn't.
  #
  # @param table [Symbol]
  # @param id [String]
  # @param at [String]
  # @param bands_changed_at [String, nil] the tenant's stamp, for a band
  def record_removed(table, id:, at:, bands_changed_at: nil)
    data = { id:, at:, changed_by_id: nil }
    data.merge!(order: nil, bands_changed_at:) if table == :pay_bands
    data[:rule] = entries(table).fetch(id).row["rule"] if table == :planning_rule_defaults
    remove = WRITES.fetch(table).fetch(:remove) or raise ArgumentError, "#{table} rows are never removed"
    apply(remove.new(data:))
  end

  NOUNS = { pay_bands: "pay band", exchange_rates: "exchange rate", budget_lines: "budget line",
            planning_rule_defaults: "rule default", reference_currencies: "reference currency" }.freeze
  private_constant :NOUNS

  WRITES.each do |table, events|
    events.values_at(:add, :change).uniq.each do |event_class|
      on(event_class) do |event|
        data = event.data
        prior = entries(table)[data[:id]]
        row = TenantPlanningInputs::Rows.complete(table, data[:row].deep_stringify_keys)
        entries(table)[data[:id]] = Entry.new(
          row:, created_at: data[:created_at] || prior&.created_at || data[:at], updated_at: data[:at],
          updated_by_person_id: data[:changed_by_id] || data[:last_changed_by_id]
        )
        band_event(data) if table == :pay_bands
      end
    end
    next unless events[:remove]

    on(events[:remove]) do |event|
      entries(table).delete(event.data[:id])
      band_event(event.data) if table == :pay_bands
    end
  end

  on(Events::PayBandsReordered) { |event| band_event(event.data) }

  private

  def held_data(table, id:, row:, at:, last_changed_by_id:, bands_changed_at:)
    data = { id:, row:, at:, changed_by_id: nil, already_held: true, last_changed_by_id: }
    data.merge!(order: nil, bands_changed_at:) if table == :pay_bands
    data
  end

  def band_event(data)
    Array(data[:order]).each_with_index do |id, index|
      entry = entries(:pay_bands)[id] or next
      entries(:pay_bands)[id] = entry.with(row: entry.row.merge("position" => index + 1))
    end
    @bands_changed_at = data[:bands_changed_at] if data[:bands_changed_at]
  end

  # A new band lands after the last band no narrower than it, so the wider
  # bands stay above the narrower ones without anyone moving them. A changed
  # band keeps its place.
  def band_data(id, row, held, at)
    refuse_second_band(id, row)
    if held
      row.merge!("position" => entries(:pay_bands).fetch(id).row["position"])
      return { order: nil, bands_changed_at: at }
    end

    order = band_order
    specificity = PayBand.specificity(**matcher(row))
    after = order.rindex { PayBand.specificity(**matcher(entries(:pay_bands).fetch(it).row)) <= specificity }
    position = after ? after + 2 : 1
    row.merge!("position" => position)
    { order: order.insert(position - 1, id), bands_changed_at: at }
  end

  def matcher(row) = row.slice("role_family_id", "role_id", "level_ordinal", "level_id", "location_key").symbolize_keys

  def refuse_second_band(id, row)
    keys = row["level_id"] ? %w[level_id location_key] : %w[role_family_id role_id level_ordinal level_id location_key]
    taken = entries(:pay_bands).any? { |other_id, entry| other_id != id && entry.row.values_at(*keys) == row.values_at(*keys) }
    return unless taken

    raise TenantPlanningInputs::Refused,
          PayBand.duplicate_message(role_name: row["role_name"], level_name: row["level_name"], location: row["location"])
  end

  def refuse_second_rate(id, row)
    pair = row.values_at("from_currency", "to_currency").sort
    taken = entries(:exchange_rates).any? do |other_id, entry|
      other_id != id && entry.row["applies_from"] == row["applies_from"] &&
        entry.row.values_at("from_currency", "to_currency").sort == pair
    end
    return unless taken

    raise TenantPlanningInputs::Refused,
          ExchangeRate.duplicate_message(row["from_currency"], row["to_currency"], row["applies_from"])
  end

  def refuse_second_rule(id, row)
    taken = entries(:planning_rule_defaults).any? { |other_id, entry| other_id != id && entry.row["rule"] == row["rule"] }
    raise ArgumentError, "Set the rule #{row['rule']} on the row that holds it" if taken
  end
end
