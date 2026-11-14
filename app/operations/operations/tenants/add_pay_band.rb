# frozen_string_literal: true

# Adds a pay band for one framework level in one location.
class Operations::Tenants::AddPayBand < Operations::Base
  include Operations::Tenants::PayBandSupport

  description "Add a pay band for a framework level (level_id, from frameworks_get) in a location: a country, " \
              "matched to the Org Graph's country ignoring case, or blank for any location. One band per level " \
              "and location; use tenants_change_pay_band to change one. Currency is an ISO 4217 code and period " \
              "is year, month or hour; figures are kept as entered, never converted or annualised. " \
              "#{Operations::Tenants::PayBandSupport::FIGURE_HELP} Refused unless the caller is a tenant admin."
  category :write
  approval :in_app

  parameter :level_id, String, required: true, allow_blank: false
  parameter :location, String
  parameter :currency, String, required: true, allow_blank: false
  parameter :period, String, required: true, allowed: PayBand::PERIODS
  PayBand::FIGURES.each do |figure|
    parameter figure, String, required: true, schema: Operations::Tenants::PayBandSupport::FIGURE_SCHEMA
  end

  # @return [Hash] the band, as tenants_pay_bands lists it
  def perform
    level = FrameworkState::Level.find_by(level_id: params[:level_id].to_s.downcase)
    raise ParameterError, "There is no such level in the framework" unless level

    band = PayBand.new(level_id: level.level_id, level_label: PayBand.level_label(level), location: params[:location],
                       currency: params[:currency], period: params[:period], **figures)
    band_payload(save_band!(band), level)
  end
end
