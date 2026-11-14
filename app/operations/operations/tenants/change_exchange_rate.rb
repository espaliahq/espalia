# frozen_string_literal: true

# Corrects a rate. Its pair and date are what it is, so changing those is
# removing it and adding another.
class Operations::Tenants::ChangeExchangeRate < Operations::Base
  include Operations::Tenants::ExchangeRateSupport

  description "Correct an exchange rate, by exchange_rate_id from tenants_exchange_rates. Its pair and " \
              "applies_from don't change: remove the rate and add another for that. Every report that " \
              "converts on a date it covers changes with it. " \
              "#{Operations::Tenants::ExchangeRateSupport::RATE_HELP} Refused unless the caller is a tenant admin."
  category :write
  approval :in_app

  parameter :exchange_rate_id, String, required: true, allow_blank: false
  parameter :rate, String, required: true, schema: Operations::Tenants::ExchangeRateSupport::RATE_SCHEMA

  # @return [Hash] the rate, as tenants_exchange_rates lists it
  def perform
    rate = find_rate(params[:exchange_rate_id])
    rate.with_lock do
      rate.rate = rate_value
      rate_payload(save_setting!(rate))
    end
  rescue ActiveRecord::RecordNotFound
    raise Operations::Base::ParameterError, "There is no such exchange rate"
  end
end
