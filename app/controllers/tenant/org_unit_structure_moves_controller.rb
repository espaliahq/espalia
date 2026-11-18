# frozen_string_literal: true

# Moves a unit into another unit's own structure from its drawer (#494),
# changing its type and those beneath it on the way. The drawer's move form
# sends a parent in another structure here.
class Tenant::OrgUnitStructureMovesController < ApplicationController
  include OrgUnitDrawer

  # GET /tenant/org_graph/units/:org_unit_id/structure_move/new?parent_id=
  def new
    authorize :org_graph, :show_units?
    render_drawer do |overview, rights|
      Views::Tenant::OrgGraph::StructureMoveStep.new(unit: @unit, overview:, rights:, effective_on: step_date,
                                                     alert: flash[:drawer_alert], parent: overview.unit(params[:parent_id]))
    end
  end

  # POST /tenant/org_graph/units/:org_unit_id/structure_move
  def create
    authorize :org_graph, :show_units?
    Operations::OrgGraph::MoveUnit.call(context: pundit_user, params: with_date(
      unit_id: @unit.id, parent_id: params[:parent_id], conversion: params.fetch(:conversion, {}).to_unsafe_h
    ))
    redirect_to edit_tenant_org_unit_path(@unit, on: drawer_on, **comparison_params), status: :see_other, notice: "Moved."
  rescue *FAILURES => e
    redirect_to new_tenant_org_unit_structure_move_path(@unit, parent_id: params[:parent_id], on: effective_on, **comparison_params),
                flash: { drawer_alert: readable(e.message) }
  end
end
