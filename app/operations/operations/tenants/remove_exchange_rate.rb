# frozen_string_literal: true

# Removes a rate. Dates it covered convert at the pair's earlier rate, or fail.
class Operations::Tenants::RemoveExchangeRate < Operations::Base
  include Operations::Tenants::ExchangeRateSupport

  description "Remove an exchange rate, by exchange_rate_id from tenants_exchange_rates. Dates it covered " \
              "convert at the pair's earlier rate, or fail until another is added. Refused unless the caller " \
              "is a tenant admin."
  category :destructive
  approval :in_app

  parameter :exchange_rate_id, String, required: true, allow_blank: false

  # @return [Hash] `{ exchange_rate_id, from_currency, to_currency, applies_from }` of the rate removed
  def perform
    rate = find_rate(params[:exchange_rate_id])
    rate.destroy!
    rate_payload(rate).slice(:exchange_rate_id, :from_currency, :to_currency, :applies_from)
  end
end
