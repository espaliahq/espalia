# frozen_string_literal: true

# The tenant's pay bands, in the order that decides which has the last word.
class Operations::Tenants::PayBands < Operations::Base
  include Operations::Tenants::PayBandSupport

  description "List the active tenant's pay bands in order, position 1 first. Of the bands that match a seat, " \
              "the last in the list has the last word. Each band gives its position, its matcher (the role " \
              "family, role, level number and location it matches on; one left out matches anything), its " \
              "currency, period (year, month or hour) and minimum, midpoint and maximum as decimal strings, as " \
              "entered and never converted. shadowed is true for a band that can never have the last word, as " \
              "a later band matches every seat it does. in_framework is false for a band whose level, role or " \
              "role family has left the framework. Give pay_band_id to read one band. Refused unless the " \
              "caller is a tenant admin."
  category :read
  approval :none

  parameter :pay_band_id, String

  # @return [Hash] `{ pay_bands: [...] }`, in order
  # @raise [Operations::Base::ParameterError] for a pay_band_id the tenant doesn't hold
  def perform
    bands = params[:pay_band_id].present? ? [ find_band(params[:pay_band_id]) ] : PayBand.order(:position).to_a
    framework = framework_for(bands)
    names = editor_names(bands)
    shadowed = shadowed_ids
    { pay_bands: bands.map { band_payload(it, framework:, names:, shadowed:) } }
  end
end
