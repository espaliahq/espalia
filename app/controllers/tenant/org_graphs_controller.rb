# frozen_string_literal: true

# The Org Graph's Units view (#80): the unit tree, the members of the unit
# opened, and the people in no team. With a date picked it marks what changed
# since (#139).
#
class Tenant::OrgGraphsController < ApplicationController
  # GET /tenant/org_graph
  def show
    authorize :org_graph, :show_units?
    comparison, error = comparison_asked_for
    render Views::Tenant::OrgGraph::ShowView.new(
      overview: OrgGraph::UnitsOverview.new(selected_unit_id: params[:unit]),
      user: current_user,
      current_tenant: ActsAsTenant.current_tenant,
      tenants: tenants_for_user,
      comparison_bar: Views::Tenant::OrgGraph::ComparisonBar.new(
        comparison:, error:, values: params.permit(:from, :to, :by).to_h, unit_id: params[:unit].presence
      ),
      comparison: comparison || OrgGraph::Comparison::NONE
    )
  end

  private

  # @return [Array(OrgGraph::DateComparison, nil), Array(nil, String)] the
  #   comparison the dates ask for, or why they make none
  def comparison_asked_for
    window = OrgGraph::DateComparison.window(from: params[:from], to: params[:to], by: params[:by])
    [ window && OrgGraph::DateComparison.new(context: pundit_user, window:), nil ]
  rescue OrgGraph::DateComparison::InvalidWindow => e
    [ nil, e.message ]
  end

  # @return [Array<Tenant>]
  def tenants_for_user
    ActsAsTenant.without_tenant { current_user.tenants.to_a }
  end
end
