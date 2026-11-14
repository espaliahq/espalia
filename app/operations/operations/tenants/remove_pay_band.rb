# frozen_string_literal: true

# Removes a pay band. A position it priced falls back to the level's
# any-location band, or to no price at all.
class Operations::Tenants::RemovePayBand < Operations::Base
  include Operations::Tenants::PayBandSupport

  description "Remove a pay band, by pay_band_id from tenants_pay_bands. Positions it priced fall back to the " \
              "level's any-location band, or go unpriced. Refused unless the caller is a tenant admin."
  category :destructive
  approval :in_app

  parameter :pay_band_id, String, required: true, allow_blank: false

  # @return [Hash] `{ pay_band_id, level, location }` of the band removed
  def perform
    band = find_band(params[:pay_band_id])
    band.destroy!
    { pay_band_id: band.id, level: band.level_label, location: band.location.presence }
  end
end
