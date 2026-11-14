# frozen_string_literal: true

# The unit drawer (#124): opens a unit over the Units view, and renames or
# moves it. Owners and members have their own controllers.
class Tenant::OrgUnitsController < ApplicationController
  include OrgUnitDrawer

  # GET /tenant/org_graph/units/:id/edit
  def edit
    authorize :org_graph, :show_units?
    overview = OrgGraph::UnitsOverview.new(selected_unit_id: @unit.id)
    confirmations = OrgGraphPolicy::Confirmations.for_cards(policy(:org_graph), overview)
    render Views::Tenant::OrgGraph::ShowView.new(
      overview:,
      user: current_user,
      current_tenant: ActsAsTenant.current_tenant,
      tenants: ActsAsTenant.without_tenant { current_user.tenants.to_a },
      confirmations:,
      drawer: Views::Tenant::OrgGraph::UnitDrawer.new(
        unit: @unit,
        overview:,
        rights: OrgGraphPolicy::UnitRights.new(policy(:org_graph), @unit, overview),
        confirmations:,
        effective_on: params[:on].presence || Date.current.iso8601,
        alert: flash[:drawer_alert]
      )
    )
  end

  # GET /tenant/org_graph/units/:id/candidates?q=
  #
  # The person picker's typeahead for owners and members: active people in
  # the tenant.
  def candidates
    authorize :org_graph, :show_units?
    render Views::Shared::PersonPickerCandidatesFrame.new(
      frame_id: params[:frame].presence_in(%w[owner-candidates member-candidates]) || "member-candidates",
      entries: OrgGraph::PersonCandidates.new.search(params[:q]),
      query: params[:q].presence
    ), layout: false
  end

  # PATCH /tenant/org_graph/units/:id
  #
  # One form renames the unit and another moves it, so a request carries a
  # name or a parent_id.
  def update
    authorize :org_graph, :show_units?
    attrs = params.expect(org_unit: [ :name, :parent_id ])
    if attrs.key?(:name)
      write(notice: "Renamed.") do
        Operations::OrgGraph::RenameUnit.call(context: pundit_user, params: with_date(unit_id: @unit.id, name: attrs[:name]))
      end
    else
      write(notice: "Moved.") do
        Operations::OrgGraph::MoveUnit.call(context: pundit_user,
                                            params: with_date(unit_id: @unit.id, parent_id: attrs[:parent_id].presence))
      end
    end
  end
end
