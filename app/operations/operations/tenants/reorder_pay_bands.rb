# frozen_string_literal: true

# Puts the tenant's pay bands in a new order.
class Operations::Tenants::ReorderPayBands < Operations::Base
  include Operations::Tenants::PayBandSupport

  description "Change the order of the tenant's pay bands. pay_band_ids lists every band once, from " \
              "tenants_pay_bands, position 1 first. Of the bands that match a seat, the last has the last word, " \
              "so moving a band can change what a seat costs: every plan reprices. Refused unless the caller is " \
              "a tenant admin."
  category :write
  approval :in_app

  parameter :pay_band_ids, Array, required: true,
            schema: { type: "array", items: { type: "string" }, description: "every pay_band_id, position 1 first" }

  # @return [Hash] `{ pay_bands: [...] }` in the new order, as tenants_pay_bands lists them
  # @raise [Operations::Base::ParameterError] unless the ids are every band once
  def perform
    order = Array(params[:pay_band_ids]).map { it.to_s.downcase }
    unless PayBand.reorder!(order)
      raise Operations::Base::ParameterError, "List every pay band once, as tenants_pay_bands lists them"
    end

    Operations::Tenants::PayBands.call(context:, params: {})
  end
end
