# frozen_string_literal: true

# Adds a pay band to the tenant's ordered list.
class Operations::Tenants::AddPayBand < Operations::Base
  include Operations::Tenants::PayBandSupport

  description "Add a pay band. #{Operations::Tenants::PayBandSupport::MATCHER_HELP} A location is a country, " \
              "matched to the Org Graph's country ignoring case, or blank for any location. Two bands can't " \
              "match on exactly the same fields; use tenants_change_pay_band to change one. Currency is an " \
              "ISO 4217 code and period is year, month or hour; figures are kept as entered, never converted " \
              "or annualised. #{Operations::Tenants::PayBandSupport::FIGURE_HELP} Refused unless the caller " \
              "is a tenant admin."
  category :write
  approval :in_app

  Operations::Tenants::PayBandSupport.declare_matcher(self)
  parameter :location, String
  parameter :currency, String, required: true, allow_blank: false
  parameter :period, String, required: true, allowed: PayBand::PERIODS
  PayBand::FIGURES.each do |figure|
    parameter figure, String, required: true, schema: Operations::Tenants::PayBandSupport::FIGURE_SCHEMA
  end

  # @return [Hash] the band, as tenants_pay_bands lists it
  def perform
    band = PayBand.new(location: params[:location], currency: params[:currency], period: params[:period], **figures)
    match!(band)
    band_payload(save_setting!(band))
  end
end
