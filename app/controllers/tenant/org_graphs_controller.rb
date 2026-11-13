# frozen_string_literal: true

# The Org Graph's Units view (#80): the unit tree, the members of the unit
# opened, and the people in no team. Read-only; editing arrives with the
# unit and person drawers.
#
class Tenant::OrgGraphsController < ApplicationController
  # GET /tenant/org_graph
  def show
    authorize :org_graph, :show_units?
    render Views::Tenant::OrgGraph::ShowView.new(
      overview: OrgGraph::UnitsOverview.new(selected_unit_id: params[:unit]),
      user: current_user,
      current_tenant: ActsAsTenant.current_tenant,
      tenants: tenants_for_user
    )
  end

  private

  # @return [Array<Tenant>]
  def tenants_for_user
    ActsAsTenant.without_tenant { current_user.tenants.to_a }
  end
end
