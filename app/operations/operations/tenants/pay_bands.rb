# frozen_string_literal: true

# The tenant's pay bands, as the pay bands screen lists them: by role, each
# role's levels from the lowest, the any-location band before the countries.
class Operations::Tenants::PayBands < Operations::Base
  include Operations::Tenants::PayBandSupport

  description "List the active tenant's pay bands: each band's framework level, location (null for any " \
              "location), currency, period (year, month or hour) and minimum, midpoint and maximum as " \
              "decimal strings, as entered and never converted. in_framework is false for a band whose " \
              "level has left the framework. Refused unless the caller is a tenant admin."
  category :read
  approval :none

  # @return [Hash] `{ pay_bands: [...] }`
  def perform
    levels = FrameworkState::Level.where(level_id: PayBand.distinct.select(:level_id)).index_by(&:level_id)
    bands = PayBand.includes(:updated_by).to_a.sort_by { |band| PayBand.page_order(band, levels[band.level_id]) }
    { pay_bands: bands.map { band_payload(it, levels[it.level_id]) } }
  end
end
