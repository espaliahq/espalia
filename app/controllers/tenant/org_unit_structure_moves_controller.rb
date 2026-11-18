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
    conversion = params.fetch(:conversion, {}).to_unsafe_h
    notice = moved_notice(OrgGraph::UnitsOverview.new(selected_unit_id: @unit.id), conversion)
    Operations::OrgGraph::MoveUnit.call(context: pundit_user, params: with_date(
      unit_id: @unit.id, parent_id: params[:parent_id], conversion:
    ))
    redirect_to edit_tenant_org_unit_path(@unit, on: drawer_on, **comparison_params), status: :see_other, notice:
  rescue *FAILURES => e
    redirect_to new_tenant_org_unit_structure_move_path(@unit, parent_id: params[:parent_id], on: effective_on, **comparison_params),
                flash: { drawer_alert: readable(e.message) }
  end

  private

  # Read before the move, so it names the structure and the types it moved into.
  def moved_notice(overview, conversion)
    parent = overview.unit(params[:parent_id])
    return "Moved." unless parent

    into = Views::Tenant::OrgGraph::StructureStep.structure_name(overview, overview.structure_beneath(parent))
    moved = "Moved #{@unit.name} into #{into}."
    return "#{moved} Their types changed." if overview.descendants_of(@unit).any?

    type = OrgTaxonomyLevel.find_by(id: conversion[@unit.level_id])
    type ? "#{moved} Its type is now #{type.name}." : moved
  end
end
