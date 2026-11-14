# frozen_string_literal: true

# The tenant's reference currency and exchange rates, as the pay bands
# screen lists them: by pair, each pair's latest rate first.
class Operations::Tenants::ExchangeRates < Operations::Base
  include Operations::Tenants::ExchangeRateSupport

  description "Read the active tenant's reference currency (null until set), the one its reports total in, " \
              "and its exchange rates: each converts one unit of from_currency to rate units of to_currency " \
              "from applies_from on. Reports convert with the rate in force on the date, or the inverse of the " \
              "reverse pair's; a pair with no rate is an error, never 1.0. Nothing is stored converted. Give " \
              "exchange_rate_id to read one rate. Refused unless the caller is a tenant admin."
  category :read
  approval :none

  parameter :exchange_rate_id, String

  # @return [Hash] `{ reference_currency:, exchange_rates: [...] }`
  # @raise [Operations::Base::ParameterError] for an exchange_rate_id the tenant doesn't hold
  def perform
    rates = if params[:exchange_rate_id].present?
              [ find_rate(params[:exchange_rate_id]) ]
    else
              ExchangeRate.order(:from_currency, :to_currency, applies_from: :desc).to_a
    end
    reference = ReferenceCurrency.current
    names = editor_names([ *rates, reference ].compact)
    { reference_currency: reference_payload(reference, names:), exchange_rates: rates.map { rate_payload(it, names:) } }
  end
end
