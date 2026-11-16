# frozen_string_literal: true

# Puts the tenant's pay bands in a new order.
class Operations::Tenants::ReorderPayBands < Operations::Base
  include Operations::Tenants::PayBandSupport

  description "Change the order of the tenant's pay bands. pay_band_ids lists every band once, from " \
              "tenants_pay_bands, position 1 first. Of the bands that match a seat, the last has the last word, " \
              "so moving a band can change what a seat costs: every plan reprices. Refused unless the caller is " \
              "a tenant admin. Pass from_pay_band_ids, the order you read, and the reorder is refused if " \
              "another change has moved the list since."
  category :write
  approval :in_app

  parameter :pay_band_ids, Array, required: true,
            schema: { type: "array", items: { type: "string" }, description: "every pay_band_id, position 1 first" }
  parameter :from_pay_band_ids, Array,
            schema: { type: "array", items: { type: "string" }, description: "the order you read from tenants_pay_bands" }

  # @return [Hash] `{ pay_bands: [...] }` in the new order, as tenants_pay_bands lists them
  # @raise [Operations::Base::ParameterError] unless the ids are every band once, in a list that hasn't moved since it was read
  def perform
    case PayBand.reorder!(ids(:pay_band_ids), from: (ids(:from_pay_band_ids) unless params[:from_pay_band_ids].nil?))
    when false then raise Operations::Base::ParameterError, "List every pay band once, as tenants_pay_bands lists them"
    when :stale then raise Operations::Base::ParameterError, "The list has changed since you read it: read tenants_pay_bands again"
    end

    Operations::Tenants::PayBands.call(context:, params: {})
  end

  private

  def ids(name) = Array(params[name]).map { it.to_s.downcase }
end
