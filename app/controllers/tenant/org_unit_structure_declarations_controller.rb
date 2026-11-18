# frozen_string_literal: true

# Gives a unit a structure of its own from its drawer (#494), then lands the
# admin on that structure in Settings to say where each type can sit.
class Tenant::OrgUnitStructureDeclarationsController < ApplicationController
  include OrgUnitDrawer

  # GET /tenant/org_graph/units/:org_unit_id/structure_declaration/new
  def new
    authorize :org_graph, :show_units?
    render_drawer do |overview, rights|
      Views::Tenant::OrgGraph::DeclareStructureStep.new(unit: @unit, overview:, rights:, effective_on: step_date,
                                                        alert: flash[:drawer_alert], fresh: params[:fresh].present?)
    end
  end

  # POST /tenant/org_graph/units/:org_unit_id/structure_declaration
  def create
    authorize :org_graph, :show_units?
    overview = OrgGraph::UnitsOverview.new(selected_unit_id: @unit.id)
    Operations::OrgGraph::DeclareStructure.call(context: pundit_user, params: with_date(unit_id: @unit.id, **declaration(overview)))
    redirect_to tenant_org_graph_settings_path(anchor: Views::Tenant::OrgGraph::Settings::LevelsPanel.anchor(@unit.id)),
                status: :see_other, notice: "#{@unit.name} has its own structure. Say here where each of its types can sit."
  rescue *FAILURES => e
    redirect_to new_tenant_org_unit_structure_declaration_path(@unit, on: effective_on, fresh: (1 if fresh?), **comparison_params),
                flash: { drawer_alert: readable(e.message) }
  end

  private

  def fresh? = params[:start] == "fresh"

  def declaration(overview) = fresh? ? fresh_declaration : copied_declaration(overview)

  # Every type a fresh structure holds can sit at the top and under every
  # other, so every unit beneath fits; Settings tightens it.
  def fresh_declaration
    names = params.fetch(:names, {})
    names = names.respond_to?(:to_unsafe_h) ? names.to_unsafe_h : names.each_with_index.to_h { |name, i| [ "new-#{i}", name ] }
    names = names.transform_values { it.to_s.strip }
    unique = names.values.compact_blank.uniq(&:downcase)
    { levels: unique.map { |name| { name:, parent_names: unique, top: true } },
      conversion: names.compact_blank.transform_values { |name| unique.find { it.casecmp?(name) } }
                       .select { |held, _| OrgGraph::StructureAggregate::UUID.match?(held) } }
  end

  # A copy keeps each type's name and rules, and names the type it copies.
  def copied_declaration(overview)
    source = overview.structure_unit_of(@unit)
    kinds = overview.taxonomy_of(source).kinds
    names = kinds.to_h { [ it.id, it.name ] }
    { copied_from: source || "top",
      levels: kinds.map do |kind|
        { name: kind.name, parent_names: kind.parent_ids.map { names.fetch(it) }, top: kind.top?, copied_from_level_id: kind.id }
      end,
      conversion: params.fetch(:conversion, {}).to_unsafe_h.transform_values { names.fetch(it.to_s, it.to_s) } }
  end
end
