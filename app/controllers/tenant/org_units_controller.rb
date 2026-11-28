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
      viewer: OrgGraphPolicy::Viewer.new(policy(:org_graph)),
      tenants: ActsAsTenant.without_tenant { current_user.tenants.to_a },
      confirmations:,
      drawer: Views::Tenant::OrgGraph::UnitDrawer.new(
        unit: @unit,
        overview:,
        rights: OrgGraphPolicy::UnitRights.new(policy(:org_graph), @unit, overview),
        confirmations:,
        effective_on: params[:on].presence || Tenant.today.iso8601,
        alert: flash[:drawer_alert],
        sync_issues: policy(:integrations).show? ? HrisSyncIssue.rows(HrisSyncIssue.where(unit_id: @unit.id)) : []
      ),
      **comparison_slots(unit_id: @unit.id)
    )
  end

  # GET /tenant/org_graph/units/:id/candidates?q=
  #
  # The person picker's typeahead for owners and members: active people in
  # the tenant. Job titles are for admins and editors.
  def candidates
    authorize :org_graph, :show_units?
    render Views::Shared::PersonPickerCandidatesFrame.new(
      frame_id: params[:frame].presence_in(%w[owner-candidates member-candidates]) || "member-candidates",
      entries: OrgGraph::PersonCandidates.new.search(params[:q], titles: policy(:org_graph).edit_structure?),
      query: params[:q].presence
    ), layout: false
  end

  # PATCH /tenant/org_graph/units/:id
  #
  # One form renames the unit, one changes its type and another moves it, so
  # a request carries a name, a level_id or a parent_id.
  def update
    authorize :org_graph, :show_units?
    attrs = params.expect(org_unit: [ :name, :level_id, :parent_id ])
    if attrs.key?(:level_id)
      write(notice: "Type changed.") do
        Operations::OrgGraph::ChangeUnitKind.call(context: pundit_user, params: with_date(unit_id: @unit.id, level_id: attrs[:level_id]))
      end
    elsif attrs.key?(:name)
      write(notice: "Renamed.") do
        Operations::OrgGraph::RenameUnit.call(context: pundit_user, params: with_date(unit_id: @unit.id, name: attrs[:name]))
      end
    elsif into_another_structure?(attrs[:parent_id])
      redirect_to new_tenant_org_unit_structure_move_path(@unit, parent_id: attrs[:parent_id], on: drawer_on, **comparison_params),
                  status: :see_other
    else
      write(notice: "Moved.") do
        Operations::OrgGraph::MoveUnit.call(context: pundit_user,
                                            params: with_date(unit_id: @unit.id, parent_id: attrs[:parent_id].presence))
      end
    end
  end

  private

  # A parent in another structure needs each type converted, which
  # the move step asks for ([#494](https://github.com/espaliahq/espalia/issues/494)).
  def into_another_structure?(parent_id)
    overview = OrgGraph::UnitsOverview.new(selected_unit_id: @unit.id)
    rights = OrgGraphPolicy::UnitRights.new(policy(:org_graph), @unit, overview)
    parent_id.blank? ? rights.root_conversion_choice? : rights.conversion_parent_choices.any? { it.id == parent_id }
  end
end
