# frozen_string_literal: true

# The tenant's pay bands, as the pay bands screen lists them: by role, each
# role's levels from the lowest, the any-location band before the countries.
class Operations::Tenants::PayBands < Operations::Base
  include Operations::Tenants::PayBandSupport

  description "List the active tenant's pay bands: each band's framework level, location (null for any " \
              "location), currency, period (year, month or hour) and minimum, midpoint and maximum as " \
              "decimal strings, as entered and never converted. in_framework is false for a band whose " \
              "level has left the framework. Give pay_band_id to read one band. Refused unless the caller " \
              "is a tenant admin."
  category :read
  approval :none

  parameter :pay_band_id, String

  # @return [Hash] `{ pay_bands: [...] }`
  # @raise [Operations::Base::ParameterError] for a pay_band_id the tenant doesn't hold
  def perform
    bands = params[:pay_band_id].present? ? [ find_band(params[:pay_band_id]) ] : PayBand.all.to_a
    levels = FrameworkState::Level.where(level_id: bands.map(&:level_id)).index_by(&:level_id)
    roles = FrameworkState::Role.where(role_id: levels.values.map(&:role_id)).index_by(&:role_id)
    names = editor_names(bands)
    payloads = bands.to_h { [ it, band_payload(it, levels[it.level_id], roles[levels[it.level_id]&.role_id], names:) ] }
    { pay_bands: bands.sort_by { PayBand.page_order(it, levels[it.level_id]) }.map { payloads[it] } }
  end
end
