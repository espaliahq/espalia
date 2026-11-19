# frozen_string_literal: true

# Withdraws a unit's own structure from its drawer ([#494](https://github.com/espaliahq/espalia/issues/494)).
class Tenant::OrgUnitStructureWithdrawalsController < ApplicationController
  include OrgUnitDrawer

  # GET /tenant/org_graph/units/:org_unit_id/structure_withdrawal/new
  def new
    authorize :org_graph, :show_units?
    render_drawer do |overview, rights|
      Views::Tenant::OrgGraph::WithdrawStructureStep.new(unit: @unit, overview:, rights:, effective_on: step_date,
                                                         alert: flash[:drawer_alert])
    end
  end

  # POST /tenant/org_graph/units/:org_unit_id/structure_withdrawal
  def create
    authorize :org_graph, :show_units?
    Operations::OrgGraph::WithdrawStructure.call(context: pundit_user, params: with_date(unit_id: @unit.id, conversion:))
    redirect_to tenant_org_graph_path(unit: @unit.id, **comparison_params), status: :see_other,
                notice: "Withdrew #{@unit.name}'s structure."
  rescue *FAILURES => e
    redirect_to new_tenant_org_unit_structure_withdrawal_path(@unit, on: effective_on, **comparison_params),
                flash: { drawer_alert: readable(e.message) }
  end

  private

  def conversion = params.fetch(:conversion, {}).to_unsafe_h
end
