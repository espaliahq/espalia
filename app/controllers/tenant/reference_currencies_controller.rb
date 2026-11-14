# frozen_string_literal: true

# The tenant's reference currency, set from the pay bands page. Tenant admins only.
class Tenant::ReferenceCurrenciesController < ApplicationController
  include PayBandsPage

  # PATCH /tenant/reference_currency
  def update
    authorize_pay_bands
    reference = Operations::Tenants::SetReferenceCurrency.call(context: pundit_user, params: reference_params)
    redirect_to tenant_pay_bands_path, notice: "Reports now total in #{reference[:currency]}.", status: :see_other
  rescue Operations::Base::ParameterError => e
    flash.now[:alert] = "The reference currency could not be set: #{e.message}."
    render_pay_bands_page(drafts: { reference: reference_params }, status: :unprocessable_content)
  end

  private

  def reference_params = params.expect(reference_currency: [ :currency ]).to_h.symbolize_keys
end
