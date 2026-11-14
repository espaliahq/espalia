# frozen_string_literal: true

# The person drawer (#132): opens one person over the Units view, with their
# teams, employment and history. Membership changes have their own controller.
class Tenant::OrgPeopleController < ApplicationController
  include OrgPersonDrawer

  # GET /tenant/org_graph/people/:id
  def show
    authorize :org_graph, :show_units?
    overview = OrgGraph::UnitsOverview.new(selected_unit_id: unit_param)
    profile = person_profile
    render Views::Tenant::OrgGraph::ShowView.new(
      overview:,
      user: current_user,
      current_tenant: ActsAsTenant.current_tenant,
      tenants: ActsAsTenant.without_tenant { current_user.tenants.to_a },
      drawer: Views::Tenant::OrgGraph::PersonDrawer.new(
        profile:,
        overview:,
        rights: OrgGraphPolicy::PersonRights.new(policy(:org_graph), @person, overview, profile.memberships),
        effective_on: chosen_day || Date.current.iso8601,
        unit_id: unit_param,
        back: back_param,
        close_href: close_path,
        alert: flash[:drawer_alert]
      ),
      **comparison_slots(unit_id: unit_param)
    )
  end

  private

  def person_profile
    read = Operations::OrgGraph::PersonGet.new(context: pundit_user, params: { person_id: @person.id })
    read.call
    read.profile
  end

  def chosen_day
    Date.iso8601(params[:on].to_s).iso8601
  rescue Date::Error
    nil
  end
end
