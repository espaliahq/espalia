# frozen_string_literal: true

# Removes a pay band. A seat it priced takes the next band above it in the
# list that matches the seat, or goes unpriced.
class Operations::Tenants::RemovePayBand < Operations::Base
  include Operations::Tenants::PayBandSupport

  description "Remove a pay band, by pay_band_id from tenants_pay_bands. Seats it priced take the next band above it " \
              "in the list that matches them, or go unpriced. Refused unless the caller is a tenant admin."
  category :destructive
  approval :in_app

  parameter :pay_band_id, String, required: true, allow_blank: false

  # @return [Hash] the band removed, as tenants_pay_bands listed it
  def perform
    band = find_band(params[:pay_band_id])
    band_payload(band, shadowed: Set.new).except(:shadowed).tap { band.destroy! }
  end
end
