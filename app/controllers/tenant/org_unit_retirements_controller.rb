# frozen_string_literal: true

# Retires a unit from its drawer (#138), ending every membership in it.
class Tenant::OrgUnitRetirementsController < ApplicationController
  include OrgUnitDrawer

  # GET /tenant/org_graph/units/:org_unit_id/retirement/new
  def new
    authorize :org_graph, :show_units?
    render_drawer do |overview, rights|
      Views::Tenant::OrgGraph::RetireStep.new(unit: @unit, overview:, rights:, effective_on: step_date,
                                              alert: flash[:drawer_alert])
    end
  end

  # POST /tenant/org_graph/units/:org_unit_id/retirement
  def create
    authorize :org_graph, :show_units?
    result = Operations::OrgGraph::RetireUnit.call(context: pundit_user, params: with_date(unit_id: @unit.id))
    ended = result[:memberships_ended]
    redirect_to tenant_org_graph_path(unit: @unit.parent_id, **comparison_params), status: :see_other,
                notice: "Retired #{@unit.name}. #{ended} #{'membership'.pluralize(ended)} ended."
  rescue *FAILURES => e
    redirect_to new_tenant_org_unit_retirement_path(@unit, on: effective_on, **comparison_params), flash: { drawer_alert: readable(e.message) }
  end
end
