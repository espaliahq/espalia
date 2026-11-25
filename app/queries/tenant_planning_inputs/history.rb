# frozen_string_literal: true

# What changed in a tenant's planning inputs, newest first: each change with
# who made it, when, and the row before and after.
#
# A removal carries only the row's id, so the history reads the whole stream
# from the start to know what each change replaced. A tenant's stream holds
# tens to hundreds of events, so this stays cheap.
#
# @example
#   history = TenantPlanningInputs::History.new(inputs: :pay_bands, page: 1)
#   history.changes # => [#<data Change ...>, ...]
class TenantPlanningInputs::History
  Events = TenantPlanningInputs::Events

  PAGE_SIZE = 25

  # Which tables each screen's history reads: the rates panel holds the
  # reference currency too.
  INPUTS = {
    pay_bands: %i[pay_bands],
    exchange_rates: %i[exchange_rates reference_currencies],
    budget_lines: %i[budget_lines],
    planning_rules: %i[planning_rule_defaults]
  }.freeze

  # The table each event writes, and what it does to its row. nil means
  # added when the row is new and changed when it isn't.
  WRITES = {
    Events::PayBandAdded => [ :pay_bands, :added ],
    Events::PayBandChanged => [ :pay_bands, :changed ],
    Events::PayBandRemoved => [ :pay_bands, :removed ],
    Events::PayBandsReordered => [ :pay_bands, :reordered ],
    Events::ExchangeRateSet => [ :exchange_rates, nil ],
    Events::ExchangeRateRemoved => [ :exchange_rates, :removed ],
    Events::ReferenceCurrencySet => [ :reference_currencies, nil ],
    Events::BudgetLineAdded => [ :budget_lines, :added ],
    Events::BudgetLineChanged => [ :budget_lines, :changed ],
    Events::BudgetLineRemoved => [ :budget_lines, :removed ],
    Events::PlanningRuleDefaultSet => [ :planning_rule_defaults, nil ],
    Events::PlanningRuleDefaultCleared => [ :planning_rule_defaults, :removed ]
  }.freeze

  # One change.
  #
  # `already_held` marks a row reconcile recorded from the table rather than a
  # command: `at` and `by_person_id` are then the row's last change before it
  # was recorded. `before` and `after` are the row as its table types read it,
  # nil where there was no row; a reorder has neither.
  Change = Data.define(:event_id, :table, :change, :row_id, :at, :by_person_id, :already_held, :before, :after)

  # @return [Integer]
  attr_reader :page

  # @param inputs [Symbol] one of {INPUTS}
  # @param page [Integer] 1 for the newest
  # @param tenant [Tenant]
  def initialize(inputs:, page: 1, tenant: ActsAsTenant.current_tenant)
    @tables = INPUTS.fetch(inputs)
    @page = [ page.to_i, 1 ].max
    @tenant = tenant
  end

  # @return [Array<Change>] this page's changes, newest first
  def changes = all.reverse.slice((page - 1) * PAGE_SIZE, PAGE_SIZE) || []

  # @return [Boolean] whether an older page follows
  def next_page? = all.size > page * PAGE_SIZE

  private

  def all
    @all ||= begin
      rows = {}
      events.filter_map do |event|
        table, change = WRITES.fetch(event.class)
        change = fold(rows, table, change, event)
        change if @tables.include?(change.table)
      end
    end
  end

  def events
    Rails.configuration.event_store.read.stream(EventStreamNaming.tenant_planning_inputs_stream(tenant: @tenant)).to_a
  end

  def fold(rows, table, change, event)
    data = event.data
    key = [ table, data[:id] ]
    before = rows[key]
    after = data[:row] && TenantPlanningInputs::Rows.cast(table, TenantPlanningInputs::Rows.complete(table, data[:row]))
    after ? rows[key] = after : rows.delete(key)

    Change.new(
      event_id: event.event_id, table:, change: change || (before ? :changed : :added), row_id: data[:id],
      at: Time.zone.parse(data[:at]), by_person_id: data[:changed_by_id] || data[:last_changed_by_id],
      already_held: data[:already_held] == true, before:, after:
    )
  end
end
