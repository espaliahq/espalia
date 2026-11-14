# frozen_string_literal: true

# Sets the one currency the tenant's reports total in.
class Operations::Tenants::SetReferenceCurrency < Operations::Base
  include Operations::Tenants::ExchangeRateSupport

  description "Set the active tenant's reference currency, an ISO 4217 code: the currency its reports total " \
              "in. Pay bands keep their own currencies; a report converts with tenants_exchange_rates' rates " \
              "and fails for a pair with none. Refused unless the caller is a tenant admin."
  category :write
  approval :in_app

  parameter :currency, String, required: true, allow_blank: false

  # @return [Hash] `{ currency, updated_at, updated_by }`
  def perform
    reference = ReferenceCurrency.current || ReferenceCurrency.new
    reference.currency = params[:currency]
    reference_payload(save_setting!(reference))
  end
end
