# frozen_string_literal: true

# Changes a pay band's currency, period or figures. Its level and location
# are what it is, so changing those is removing it and adding another.
class Operations::Tenants::ChangePayBand < Operations::Base
  include Operations::Tenants::PayBandSupport

  description "Change a pay band's currency, period and minimum, midpoint and maximum, by pay_band_id from " \
              "tenants_pay_bands. All are required, as the band reads afterwards. Its level and location don't " \
              "change: remove the band and add another for that. Every plan priced from it reprices. " \
              "#{Operations::Tenants::PayBandSupport::FIGURE_HELP} Refused unless the caller is a tenant admin."
  category :write
  approval :in_app

  parameter :pay_band_id, String, required: true, allow_blank: false
  parameter :currency, String, required: true, allow_blank: false
  parameter :period, String, required: true, allowed: PayBand::PERIODS
  PayBand::FIGURES.each do |figure|
    parameter figure, String, required: true, schema: Operations::Tenants::PayBandSupport::FIGURE_SCHEMA
  end

  # @return [Hash] the band, as tenants_pay_bands lists it
  def perform
    band = find_band(params[:pay_band_id])
    band.with_lock do
      level = FrameworkState::Level.find_by(level_id: band.level_id)
      band.level = level if level
      band.assign_attributes(currency: params[:currency], period: params[:period], **figures)
      band_payload(save_band!(band))
    end
  end
end
