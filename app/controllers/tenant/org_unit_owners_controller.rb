# frozen_string_literal: true

# Names and removes a unit's owners from the unit drawer (#124).
class Tenant::OrgUnitOwnersController < ApplicationController
  include OrgUnitDrawer

  # POST /tenant/org_graph/units/:org_unit_id/owners
  def create
    authorize :org_graph, :show_units?
    person_ids = Array(params[:person_ids]).compact_blank
    return redirect_to(drawer_path, flash: { drawer_alert: "Choose someone to own #{@unit.name}." }) if person_ids.empty?

    write_each(person_ids, notice: person_ids.one? ? "Owner added." : "Owners added.") do |person_id|
      Operations::OrgGraph::AddUnitOwner.call(context: pundit_user, params: with_date(unit_id: @unit.id, person_id:))
    end
  end

  # DELETE /tenant/org_graph/units/:org_unit_id/owners/:id
  def destroy
    authorize :org_graph, :show_units?
    write(notice: "Owner removed.", status: :see_other) do
      Operations::OrgGraph::RemoveUnitOwner.call(context: pundit_user, params: with_date(unit_id: @unit.id, person_id: params[:id]))
    end
  end
end
