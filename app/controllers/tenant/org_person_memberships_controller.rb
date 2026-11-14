# frozen_string_literal: true

# Adds, moves and ends one person's memberships from the person drawer
# (#132), through the unit drawer's operations. The `:id` is the unit's.
class Tenant::OrgPersonMembershipsController < ApplicationController
  include OrgPersonDrawer

  # POST /tenant/org_graph/people/:org_person_id/memberships
  def create
    authorize :org_graph, :show_units?
    unit_id = params[:unit_id].presence
    return redirect_to(drawer_path, flash: { drawer_alert: "Choose a team to add #{@person.name} to." }) unless unit_id

    write(notice: "Added to #{unit_name(unit_id)}.") do
      Operations::OrgGraph::AddMember.call(
        context: pundit_user,
        params: with_date(unit_id:, person_id: @person.id, **{ role: params[:role].presence, allocation: }.compact)
      )
    end
  end

  # PATCH /tenant/org_graph/people/:org_person_id/memberships/:id
  def update
    authorize :org_graph, :show_units?
    write(notice: "Moved to #{unit_name(params[:unit_id])}.") do
      Operations::OrgGraph::MoveMember.call(
        context: pundit_user,
        params: with_date(person_id: @person.id, from_unit_id: params[:id], unit_id: params.expect(:unit_id))
      )
    end
  end

  # DELETE /tenant/org_graph/people/:org_person_id/memberships/:id
  def destroy
    authorize :org_graph, :show_units?
    write(notice: "Left #{unit_name(params[:id])}.", status: :see_other) do
      Operations::OrgGraph::RemoveMember.call(context: pundit_user, params: with_date(person_id: @person.id, unit_id: params[:id]))
    end
  end

  private

  def unit_name(unit_id) = OrgUnit.find_by(id: unit_id)&.name || "the team"
end
