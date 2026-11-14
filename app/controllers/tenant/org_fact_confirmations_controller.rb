# frozen_string_literal: true

# "Still true" (#142): confirms one person's stale membership or facts as of
# today, then goes back to the screen the button was on: the person drawer,
# the Units view or the unit drawer.
class Tenant::OrgFactConfirmationsController < ApplicationController
  include OrgPersonDrawer

  # POST /tenant/org_graph/people/:org_person_id/confirmations
  def create
    authorize :org_graph, :show_units?
    facts = Array(params[:facts]).compact_blank
    return redirect_back_with(alert: "Choose a fact to confirm.") if facts.empty?

    facts.each do |fact|
      Operations::OrgGraph::ConfirmFact.call(
        context: pundit_user,
        params: { person_id: @person.id, fact:, unit_id: (params[:unit_id] if fact == "membership") }.compact
      )
    end
    redirect_back_with(notice: "Confirmed as still true.")
  rescue *OrgUnitDrawer::FAILURES => e
    redirect_back_with(alert: readable(e.message))
  end

  private

  def redirect_back_with(notice: nil, alert: nil)
    if params[:return_to] == "units"
      redirect_to tenant_org_graph_path(unit: unit_param, **comparison_params), notice:, alert:
    elsif params[:return_to] == "unit" && unit_param
      redirect_to edit_tenant_org_unit_path(unit_param), notice:, flash: { drawer_alert: alert }.compact
    else
      redirect_to drawer_path, notice:, flash: { drawer_alert: alert }.compact
    end
  end

  # The comparison open in the Units view, kept so Still true doesn't close it.
  def comparison_params = params.permit(:from, :to, :by).to_h.compact_blank.symbolize_keys
end
