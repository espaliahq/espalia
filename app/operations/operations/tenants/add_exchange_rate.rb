# frozen_string_literal: true

# Adds a rate for a currency pair from a date.
class Operations::Tenants::AddExchangeRate < Operations::Base
  include Operations::Tenants::ExchangeRateSupport

  description "Add an exchange rate: one unit of from_currency is worth rate units of to_currency from " \
              "applies_from (YYYY-MM-DD) until a later rate for the pair applies. Both are ISO 4217 codes. One " \
              "rate per pair and date, either way round; use tenants_change_exchange_rate to correct one. " \
              "#{Operations::Tenants::ExchangeRateSupport::RATE_HELP} Refused unless the caller is a tenant admin."
  category :write
  approval :in_app

  parameter :from_currency, String, required: true, allow_blank: false
  parameter :to_currency, String, required: true, allow_blank: false
  parameter :rate, String, required: true, schema: Operations::Tenants::ExchangeRateSupport::RATE_SCHEMA
  parameter :applies_from, String, required: true, schema: Operations::OrgGraph::DateParameter::DATE_SCHEMA

  # @return [Hash] the rate, as tenants_exchange_rates lists it
  def perform
    rate = ExchangeRate.new(from_currency: params[:from_currency], to_currency: params[:to_currency],
                            rate: rate_value, applies_from: parse_date(:applies_from))
    rate_payload(save_setting!(rate))
  end
end
