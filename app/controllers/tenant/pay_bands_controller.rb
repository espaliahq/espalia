# frozen_string_literal: true

# The tenant's pay bands (Team Planning 5.1): what each framework level pays,
# by country. Tenant admins only. A refused form is shown again with what was
# typed, so nothing has to be entered twice.
class Tenant::PayBandsController < ApplicationController
  include PayBandsPage

  FIELDS = %i[level_id location currency period minimum midpoint maximum].freeze

  # GET /tenant/pay_bands
  def index
    authorize_pay_bands
    render_pay_bands_page
  end

  # POST /tenant/pay_bands
  def create
    authorize_pay_bands
    band = Operations::Tenants::AddPayBand.call(context: pundit_user, params: band_params)
    redirect_to tenant_pay_bands_path, notice: "Band added for #{band[:level]}, #{location_name(band)}.", status: :see_other
  rescue Operations::Base::ParameterError => e
    flash.now[:alert] = "The band could not be added: #{e.message}."
    render_pay_bands_page(drafts: { band: band_params }, status: :unprocessable_content)
  end

  # GET /tenant/pay_bands/:id/edit
  def edit
    authorize_pay_bands
    render_edit(band_payload)
  end

  # PATCH /tenant/pay_bands/:id
  def update
    authorize_pay_bands
    band = Operations::Tenants::ChangePayBand.call(context: pundit_user,
                                                   params: band_params.except(:level_id, :location).merge(pay_band_id: params[:id]))
    redirect_to tenant_pay_bands_path, notice: "Band changed for #{band[:level]}, #{location_name(band)}.", status: :see_other
  rescue Operations::Base::ParameterError => e
    flash.now[:alert] = "The band could not be changed: #{e.message}."
    render_edit(band_payload.merge(band_params.except(:level_id, :location)), status: :unprocessable_content)
  end

  # DELETE /tenant/pay_bands/:id
  def destroy
    authorize_pay_bands
    band = Operations::Tenants::RemovePayBand.call(context: pundit_user, params: { pay_band_id: params[:id] })
    redirect_to tenant_pay_bands_path, notice: "Band removed for #{band[:level]}, #{location_name(band)}.", status: :see_other
  rescue Operations::Base::ParameterError => e
    redirect_to tenant_pay_bands_path, alert: "The band could not be removed: #{e.message}.", status: :see_other
  end

  private

  def render_edit(band, status: :ok)
    render Views::Tenant::PayBands::EditView.new(band:, **admin_shell), status:
  end

  # @raise [ActiveRecord::RecordNotFound] for a band this tenant doesn't hold, which renders a 404
  def band_payload
    Operations::Tenants::PayBands.call(context: pundit_user, params: { pay_band_id: params[:id] })[:pay_bands].sole
  rescue Operations::Base::ParameterError
    raise ActiveRecord::RecordNotFound
  end

  # Commas only in thousands groups, so a decimal comma such as 52,50 is refused rather than read as 5250.
  GROUPED = /\A\d{1,3}(,\d{3})+(\.\d+)?\z/

  # Figures arrive as typed, so the spaces and thousands separators a person types are dropped here.
  def band_params
    values = params.expect(pay_band: FIELDS).to_h.symbolize_keys
    PayBand::FIGURES.each { |name| values[name] = ungrouped(values[name]) if values.key?(name) }
    values
  end

  def ungrouped(figure)
    figure = figure.to_s.delete(" ")
    figure.match?(GROUPED) ? figure.delete(",") : figure
  end

  def location_name(band) = band[:location] || "any location"
end
