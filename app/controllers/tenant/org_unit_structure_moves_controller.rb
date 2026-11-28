# frozen_string_literal: true

# Moves a unit into another structure from its drawer ([#494](https://github.com/espaliahq/espalia/issues/494), [#521](https://github.com/espaliahq/espalia/issues/521)),
# changing its type and those its structure governs on the way. The drawer's move form
# sends a parent in another structure here.
class Tenant::OrgUnitStructureMovesController < ApplicationController
  include OrgUnitDrawer

  skip_before_action :set_unit, only: :new

  # GET /tenant/org_graph/units/:org_unit_id/structure_move/new?parent_id=
  #
  # Only an admin or an editor, who sees every unit, hears that one isn't
  # there. Anyone else is refused alike for a unit out of reach, retired or
  # made up, so the step doesn't say which units exist.
  def new
    authorize :org_graph, :show_units?
    @unit = OrgUnit.live.find_by(id: params[:org_unit_id])
    return set_unit if @unit.nil? && policy(:org_graph).edit_structure?
    unless @unit && policy(:org_graph).edit_unit?(@unit)
      raise Pundit::NotAuthorizedError, query: :edit_unit?, record: :org_graph, policy: policy(:org_graph)
    end

    render_drawer do |overview, rights|
      Views::Tenant::OrgGraph::StructureMoveStep.new(unit: @unit, overview:, rights:, effective_on: step_date,
                                                     alert: flash[:drawer_alert], parent: overview.unit(params[:parent_id]),
                                                     to_top: params[:parent_id].blank?, carried: carried_choices)
    end
  end

  # POST /tenant/org_graph/units/:org_unit_id/structure_move
  def create
    authorize :org_graph, :show_units?
    conversion = params.fetch(:conversion, {}).to_unsafe_h
    notice = moved_notice(OrgGraph::UnitsOverview.new(selected_unit_id: @unit.id), conversion)
    Operations::OrgGraph::MoveUnit.call(context: pundit_user, params: with_date(
      unit_id: @unit.id, parent_id: params[:parent_id].presence, conversion:
    ))
    redirect_to edit_tenant_org_unit_path(@unit, on: drawer_on, **comparison_params), status: :see_other, notice:
  rescue *FAILURES => e
    redirect_to new_tenant_org_unit_structure_move_path(@unit, parent_id: params[:parent_id], on: effective_on,
                                                              **carried_choices.symbolize_keys, **comparison_params),
                flash: { drawer_alert: readable(e.message) }
  end

  private

  # Read before the move, so it names the structure and the types it moved into.
  def moved_notice(overview, conversion)
    parent = overview.unit(params[:parent_id])
    return "Moved." if params[:parent_id].present? && parent.nil?

    into = Views::Tenant::OrgGraph::StructureStep.structure_name(overview, overview.structure_beneath(parent))
    moved = "Moved #{@unit.name} into #{into}."
    return "#{moved} Their types changed." if overview.converted_with(@unit).many?

    type = OrgTaxonomyLevel.find_by(id: conversion[@unit.level_id])
    type ? "#{moved} Its type is now #{type.name}." : moved
  end
end
