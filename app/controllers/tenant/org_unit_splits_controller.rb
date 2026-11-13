# frozen_string_literal: true

# Splits a unit from its drawer (#138). The step names the new units, then
# places each member in one, then shows who will be in no team before the
# split is applied.
class Tenant::OrgUnitSplitsController < ApplicationController
  include OrgUnitDrawer

  # GET /tenant/org_graph/units/:org_unit_id/split/new
  def new
    authorize :org_graph, :show_units?
    render_drawer do |overview, rights|
      Views::Tenant::OrgGraph::SplitStep.new(
        unit: @unit, overview:, rights:, effective_on: step_date, alert: flash[:drawer_alert],
        names: successor_names, placements:, stage: params[:stage]
      )
    end
  end

  # POST /tenant/org_graph/units/:org_unit_id/split
  def create
    authorize :org_graph, :show_units?
    names = successor_names
    Operations::OrgGraph::SplitUnit.call(context: pundit_user,
                                         params: with_date(unit_id: @unit.id, successor_names: names, placements:))
    redirect_to tenant_org_graph_path(unit: @unit.parent_id), status: :see_other,
                notice: "Split #{@unit.name} into #{names.to_sentence}."
  rescue *FAILURES => e
    redirect_to new_tenant_org_unit_split_path(@unit, on: effective_on, names:, placements:, stage: "review"),
                flash: { drawer_alert: readable(e.message) }
  end

  private

  def successor_names = Array(params[:names]).map { |name| name.to_s.strip }.compact_blank

  # Only people placed in a team; "No team" sends a blank.
  def placements
    (params.permit(placements: {})[:placements]&.to_h || {}).transform_values { |name| name.to_s.strip }.compact_blank
  end
end
