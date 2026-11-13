# frozen_string_literal: true

# The person drawer (#132): opens one person over the Units view, with their
# teams, employment and history. Membership changes have their own controller.
class Tenant::OrgPeopleController < ApplicationController
  include OrgPersonDrawer

  # GET /tenant/org_graph/people/:id
  def show
    authorize :org_graph, :show_units?
    overview = OrgGraph::UnitsOverview.new(selected_unit_id: unit_param)
    profile = OrgGraph::PersonProfile.new(@person)
    render Views::Tenant::OrgGraph::ShowView.new(
      overview:,
      user: current_user,
      current_tenant: ActsAsTenant.current_tenant,
      tenants: ActsAsTenant.without_tenant { current_user.tenants.to_a },
      drawer: Views::Tenant::OrgGraph::PersonDrawer.new(
        profile:,
        overview:,
        rights: OrgGraphPolicy::PersonRights.new(policy(:org_graph), @person, overview, profile.memberships),
        effective_on: params[:on].presence || Date.current.iso8601,
        unit_id: unit_param,
        alert: flash[:drawer_alert]
      )
    )
  end
end
