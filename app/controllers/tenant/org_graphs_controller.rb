# frozen_string_literal: true

# The Org Graph's Units view (#80): the unit tree, the members of the unit
# opened, the people in no team, and the opened unit's activity beside them,
# where a change can be changed back (#137). With `activity=organisation`, or
# in a tenant with no units yet, the sidebar shows the organisation's own
# activity instead, behind the same check as the rest. With a date picked it marks what
# changed since (#139).
#
class Tenant::OrgGraphsController < ApplicationController
  include OrgGraphComparison

  # GET /tenant/org_graph
  def show
    authorize :org_graph, :show_units?
    overview = OrgGraph::UnitsOverview.new(selected_unit_id: params[:unit])
    render Views::Tenant::OrgGraph::ShowView.new(
      overview:,
      user: current_user,
      current_tenant: ActsAsTenant.current_tenant,
      viewer: OrgGraphPolicy::Viewer.new(policy(:org_graph)),
      tenants: tenants_for_user,
      sidebar: activity_sidebar(overview),
      confirmations: OrgGraphPolicy::Confirmations.for_cards(policy(:org_graph), overview),
      **comparison_slots(unit_id: params[:unit].presence)
    )
  end

  # POST /tenant/org_graph/change_back
  def change_back
    authorize :org_graph, :edit_structure?
    if params[:entry_id].present?
      Operations::OrgGraph::ChangeBack.call(context: pundit_user, params: { entry_id: params[:entry_id] })
    else
      Operations::OrgGraph::ChangeBackGroup.call(context: pundit_user, params: { cause_id: params[:cause_id] })
    end
    redirect_to activity_path, notice: "Changed back."
  rescue Operations::Base::ParameterError, OrgGraph::Authorization::Refused => e
    redirect_to activity_path, alert: e.message
  end

  private

  def activity_path
    tenant_org_graph_path(unit: params[:unit], activity: params[:activity].presence,
                          activity_page: params[:activity_page].presence, **comparison_params)
  end

  # The organisation's activity is for admins and editors, so anyone else
  # sees the opened unit's, or no sidebar while none is open.
  def activity_sidebar(overview)
    allowed = policy(:org_graph).edit_structure?
    organisation = overview.selected.nil? || (allowed && params[:activity] == Views::Tenant::OrgGraph::ActivitySidebar::ORGANISATION)
    return if organisation && !allowed

    feed = OrgGraph::ActivityFeed.new(unit: (overview.selected unless organisation), actor: pundit_user,
                                      page: params[:activity_page] || 1)
    Views::Tenant::OrgGraph::ActivitySidebar.new(feed:, open_unit: overview.selected, organisation: allowed)
  end

  # @return [Array<Tenant>]
  def tenants_for_user
    ActsAsTenant.without_tenant { current_user.tenants.to_a }
  end
end
