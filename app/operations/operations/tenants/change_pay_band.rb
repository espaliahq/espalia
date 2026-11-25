# frozen_string_literal: true

# Changes a pay band in place, keeping its position in the list.
class Operations::Tenants::ChangePayBand < Operations::Base
  include Operations::Tenants::PayBandSupport

  description "Change a pay band, by pay_band_id from tenants_pay_bands. Currency, period and minimum, midpoint " \
              "and maximum are required, as the band reads afterwards. Give any of role_family_id, role_id, " \
              "level_ordinal or level_id to change what it matches on: those given replace the whole matcher, and " \
              "role_id given blank on its own widens the band to every role and level. " \
              "Give location to move it, blank for any location. The band keeps its position; " \
              "tenants_reorder_pay_bands moves it. Every plan priced from it reprices. " \
              "#{Operations::Tenants::PayBandSupport::MATCHER_HELP} " \
              "#{Operations::Tenants::PayBandSupport::FIGURE_HELP} Refused unless the caller is a tenant admin."
  category :write
  approval :in_app

  parameter :pay_band_id, String, required: true, allow_blank: false
  Operations::Tenants::PayBandSupport.declare_matcher(self)
  parameter :location, String
  parameter :currency, String, required: true, allow_blank: false
  parameter :period, String, required: true, allowed: PayBand::PERIODS
  PayBand::FIGURES.each do |figure|
    parameter figure, String, required: true, schema: Operations::Tenants::PayBandSupport::FIGURE_SCHEMA
  end

  # @return [Hash] the band, as tenants_pay_bands lists it
  def perform
    band = save_setting!(:pay_bands) do
      find_band(params[:pay_band_id]).tap do |band|
        matcher_given? ? match!(band) : take_current_names(band, framework_for([ band ]))
        band.location = params[:location] unless params[:location].nil?
        band.assign_attributes(currency: params[:currency], period: params[:period], **figures)
      end
    end
    band_payload(band)
  end
end
