# frozen_string_literal: true

# Merges a unit into another from its drawer (#138): everyone in it moves to
# the unit that survives.
class Tenant::OrgUnitMergesController < ApplicationController
  include OrgUnitDrawer

  # GET /tenant/org_graph/units/:org_unit_id/merge/new
  def new
    authorize :org_graph, :show_units?
    render_drawer do |overview, rights|
      Views::Tenant::OrgGraph::MergeStep.new(unit: @unit, overview:, rights:, effective_on: step_date,
                                             alert: flash[:drawer_alert])
    end
  end

  # POST /tenant/org_graph/units/:org_unit_id/merge
  def create
    authorize :org_graph, :show_units?
    into_unit_id = params[:into_unit_id].presence
    result = Operations::OrgGraph::MergeUnit.call(context: pundit_user,
                                                  params: with_date(unit_id: @unit.id, into_unit_id:))
    into = OrgUnit.find(result[:into_unit_id])
    redirect_to edit_tenant_org_unit_path(into, **comparison_params), status: :see_other, notice: "Merged #{@unit.name} into #{into.name}."
  rescue *FAILURES => e
    redirect_to new_tenant_org_unit_merge_path(@unit, on: effective_on, **comparison_params), flash: { drawer_alert: readable(e.message) }
  end
end
