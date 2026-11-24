# frozen_string_literal: true

# The five tables a tenant's plans are priced from, and how a row travels in
# an event: each column as JSON writes it, so the stream, the table and a
# rebuild hold the same values.
module TenantPlanningInputs::Rows
  TABLES = {
    pay_bands: "PayBand",
    exchange_rates: "ExchangeRate",
    reference_currencies: "ReferenceCurrency",
    budget_lines: "BudgetLine",
    planning_rule_defaults: "PlanningRuleDefault"
  }.freeze

  # Written by the projection from the event itself, not from the row.
  BOOKKEEPING = %w[id tenant_id created_at updated_at updated_by_id updated_by_person_id].freeze

  # @param table [Symbol] one of {TABLES}
  # @return [Class<ApplicationRecord>]
  def self.model(table) = TABLES.fetch(table).constantize

  # @param table [Symbol]
  # @return [Array<String>] the columns an event carries
  def self.columns(table) = model(table).column_names - BOOKKEEPING

  # @param table [Symbol]
  # @param record [ApplicationRecord]
  # @return [Hash{String => Object}] the row's columns, as an event carries them
  def self.dump(table, record)
    columns(table).to_h { [ it, dump_value(model(table).type_for_attribute(it).type, record.public_send(it)) ] }
  end

  # A row as the table's columns now stand: an event recorded before a
  # column was added reads it as the column's default, and a dropped column
  # is left out. Without this, one added column fails every rebuild, as
  # insert_all needs every row to name the same columns.
  #
  # @param table [Symbol]
  # @param row [Hash]
  # @return [Hash{String => Object}]
  def self.complete(table, row)
    row = row.stringify_keys
    defaults = model(table).column_defaults
    columns(table).to_h { [ it, row.fetch(it) { defaults[it] } ] }
  end

  # The row as the table types read it, so a row from the table and one from
  # the stream compare equal when the table holds what the stream does.
  #
  # @param table [Symbol]
  # @param values [Hash{String => Object}]
  # @return [Hash{String => Object}]
  def self.cast(table, values)
    model = model(table)
    values.to_h do |column, value|
      cast = model.type_for_attribute(column.to_s).cast(value)
      [ column.to_s, cast.is_a?(Hash) ? cast.deep_stringify_keys : cast ]
    end
  end

  # @param time [Time]
  # @return [String] to the microsecond, as Postgres holds it
  def self.time(time) = time.utc.iso8601(6)

  def self.dump_value(type, value)
    return value if value.nil?

    case type
    when :decimal then value.to_s("F")
    when :date then value.iso8601
    when :datetime then time(value)
    when :jsonb, :json then value.deep_stringify_keys
    else value
    end
  end
  private_class_method :dump_value
end
