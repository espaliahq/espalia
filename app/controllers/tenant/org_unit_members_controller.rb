# frozen_string_literal: true

# Places, moves and removes a unit's members from the unit drawer (#124).
# The `:id` is the person's.
class Tenant::OrgUnitMembersController < ApplicationController
  include OrgUnitDrawer

  # POST /tenant/org_graph/units/:org_unit_id/members
  def create
    authorize :org_graph, :show_units?
    person_ids = Array(params[:person_ids]).compact_blank
    return redirect_to(drawer_path, flash: { drawer_alert: "Choose someone to add to #{@unit.name}." }) if person_ids.empty?

    terms = nil
    write_each(person_ids, notice: person_ids.one? ? "Added to #{@unit.name}." : "#{person_ids.size} people added to #{@unit.name}.") do |person_id|
      terms ||= { role: params[:role].presence, allocation: }.compact
      Operations::OrgGraph::AddMember.call(context: pundit_user, params: with_date(unit_id: @unit.id, person_id:, **terms))
    end
  end

  # PATCH /tenant/org_graph/units/:org_unit_id/members/:id
  def update
    authorize :org_graph, :show_units?
    write(notice: "Moved.") do
      Operations::OrgGraph::MoveMember.call(
        context: pundit_user,
        params: with_date(person_id: params[:id], from_unit_id: @unit.id, unit_id: params.expect(:unit_id))
      )
    end
  end

  # DELETE /tenant/org_graph/units/:org_unit_id/members/:id
  def destroy
    authorize :org_graph, :show_units?
    write(notice: "Removed from #{@unit.name}.", status: :see_other) do
      Operations::OrgGraph::RemoveMember.call(context: pundit_user, params: with_date(person_id: params[:id], unit_id: @unit.id))
    end
  end
end
