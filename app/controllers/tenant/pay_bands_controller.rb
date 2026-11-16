# frozen_string_literal: true

# The tenant's pay bands (Team Planning 5.1): an ordered list where the last
# band to match a seat prices it ([#368](https://github.com/espaliahq/espalia/issues/368)). Tenant admins only. A refused form is shown again with what was
# typed, so nothing has to be entered twice.
class Tenant::PayBandsController < ApplicationController
  include PayBandsPage

  FIELDS = %i[reach level_ordinal location currency period minimum midpoint maximum].freeze
  TERMS = %i[currency period minimum midpoint maximum].freeze

  # GET /tenant/pay_bands
  def index
    authorize_pay_bands
    render_pay_bands_page
  end

  # POST /tenant/pay_bands
  def create
    authorize_pay_bands
    band = Operations::Tenants::AddPayBand.call(context: pundit_user, params: matcher_params.merge(band_params.slice(*TERMS)))
    redirect_to tenant_pay_bands_path, notice: "Band added for #{band_name(band)} at #{band[:position]} in the list.",
                                       status: :see_other
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
                                                   params: band_params.slice(*TERMS).merge(pay_band_id: params[:id]))
    redirect_to tenant_pay_bands_path, notice: "Band changed for #{band_name(band)}.", status: :see_other
  rescue Operations::Base::ParameterError => e
    flash.now[:alert] = "The band could not be changed: #{e.message}."
    render_edit(band_payload.merge(band_params.slice(*TERMS)), status: :unprocessable_content)
  end

  # DELETE /tenant/pay_bands/:id
  def destroy
    authorize_pay_bands
    band = Operations::Tenants::RemovePayBand.call(context: pundit_user, params: { pay_band_id: params[:id] })
    redirect_to tenant_pay_bands_path, notice: "Band removed for #{band_name(band)}.", status: :see_other
  rescue Operations::Base::ParameterError => e
    redirect_to tenant_pay_bands_path, alert: "The band could not be removed: #{e.message}.", status: :see_other
  end

  # PATCH /tenant/pay_bands/reorder
  #
  # One band up or down a place, from its buttons, or the whole list in a new
  # order, from a drag.
  def reorder
    authorize_pay_bands
    from, ids = new_order
    return list_changed unless ids

    bands = Operations::Tenants::ReorderPayBands.call(context: pundit_user, params: { pay_band_ids: ids, from_pay_band_ids: from })[:pay_bands]
    redirect_to tenant_pay_bands_path, notice: reorder_notice(bands), status: :see_other
  rescue Operations::Base::ParameterError
    list_changed
  end

  private

  # A drag and a move button both send the order the page showed, so a list
  # another admin has moved since refuses rather than undoing their move.
  #
  # @return [Array(Array<String>, Array<String>)] the order the page showed and every band's id in the new order;
  #   the new order is nil when the band to move is gone or can't move that way
  def new_order
    from = params[:from_pay_band_ids]&.then { Array(it).map(&:to_s) }
    return [ from, Array(params[:pay_band_ids]).map(&:to_s) ] if params.key?(:pay_band_ids)

    index = from&.index(params[:pay_band_id]) or return [ from, nil ]
    other = params[:direction] == "up" ? index - 1 : index + 1
    return [ from, nil ] unless other.between?(0, from.size - 1)

    ids = from.dup
    ids[index], ids[other] = ids[other], ids[index]
    [ from, ids ]
  end

  # The page was out of date: a band was added, removed or moved since it loaded.
  def list_changed
    redirect_to tenant_pay_bands_path, alert: "The list changed since you opened it, so nothing moved. Here it is as it stands.",
                                       status: :see_other
  end

  def reorder_notice(bands)
    band = bands.find { it[:pay_band_id] == params[:pay_band_id] }
    band ? "Moved the band for #{band_name(band)} to #{band[:position]} in the list." : "Saved the new order."
  end

  # "family:<id>" or "role:<id>" from the Who picker, and a level number.
  def matcher_params
    kind, id = band_params[:reach].to_s.split(":", 2)
    ordinal = band_params[:level_ordinal].presence
    { role_family_id: (id if kind == "family"), role_id: (id if kind == "role"),
      level_ordinal: ordinal&.to_i, location: band_params[:location] }
  end

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
    @band_params ||= params.expect(pay_band: FIELDS).to_h.symbolize_keys.tap do |values|
      PayBand::FIGURES.each { |name| values[name] = ungrouped(values[name]) if values.key?(name) }
    end
  end

  def ungrouped(figure)
    figure = figure.to_s.delete(" ")
    figure.match?(GROUPED) ? figure.delete(",") : figure
  end

  def band_name(band) = Views::Tenant::PayBands::BandText.band_name(band)
end
