# frozen_string_literal: true

# The exchange rates on the pay bands page (Team Planning 5.3). Tenant admins
# only, as the bands are. A rate's pair and date are its key, so changing a
# rate corrects only its value.
class Tenant::ExchangeRatesController < ApplicationController
  include PayBandsPage

  FIELDS = %i[from_currency to_currency rate applies_from].freeze

  # POST /tenant/exchange_rates
  def create
    authorize_pay_bands
    rate = Operations::Tenants::AddExchangeRate.call(context: pundit_user, params: rate_params)
    redirect_to tenant_pay_bands_path, notice: "Rate added for #{pair(rate)} from #{day(rate)}.", status: :see_other
  rescue Operations::Base::ParameterError => e
    flash.now[:alert] = "The rate could not be added: #{e.message}."
    render_pay_bands_page(drafts: { rate: rate_params }, status: :unprocessable_content)
  end

  # GET /tenant/exchange_rates/:id/edit
  def edit
    authorize_pay_bands
    render_edit(rate_payload)
  end

  # PATCH /tenant/exchange_rates/:id
  def update
    authorize_pay_bands
    rate = Operations::Tenants::ChangeExchangeRate.call(context: pundit_user,
                                                        params: rate_params.slice(:rate).merge(exchange_rate_id: params[:id]))
    redirect_to tenant_pay_bands_path, notice: "Rate changed for #{pair(rate)} from #{day(rate)}.", status: :see_other
  rescue Operations::Base::ParameterError => e
    flash.now[:alert] = "The rate could not be changed: #{e.message}."
    render_edit(rate_payload.merge(rate_params.slice(:rate)), status: :unprocessable_content)
  end

  # DELETE /tenant/exchange_rates/:id
  def destroy
    authorize_pay_bands
    rate = Operations::Tenants::RemoveExchangeRate.call(context: pundit_user, params: { exchange_rate_id: params[:id] })
    redirect_to tenant_pay_bands_path, notice: "Rate removed for #{pair(rate)} from #{day(rate)}.", status: :see_other
  rescue Operations::Base::ParameterError => e
    redirect_to tenant_pay_bands_path, alert: "The rate could not be removed: #{e.message}.", status: :see_other
  end

  private

  def render_edit(rate, status: :ok)
    render Views::Tenant::ExchangeRates::EditView.new(rate:, **admin_shell), status:
  end

  # @raise [ActiveRecord::RecordNotFound] for a rate this tenant doesn't hold, which renders a 404
  def rate_payload
    Operations::Tenants::ExchangeRates.call(context: pundit_user, params: { exchange_rate_id: params[:id] })[:exchange_rates].sole
  rescue Operations::Base::ParameterError
    raise ActiveRecord::RecordNotFound
  end

  def rate_params
    values = params.expect(exchange_rate: FIELDS).to_h.symbolize_keys
    values[:rate] = values[:rate].to_s.delete(" ") if values.key?(:rate)
    values
  end

  def pair(rate) = "#{rate[:from_currency]} to #{rate[:to_currency]}"

  def day(rate) = Views::Tenant::PayBands::BandText.day_text(rate[:applies_from])
end
