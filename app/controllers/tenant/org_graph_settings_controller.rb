# frozen_string_literal: true

# The Org Graph's settings screen (#126). It reads through the Operations the
# MCP server shares, and each panel's writes have a controller of their own
# under {Tenant::OrgGraphSettings}.
class Tenant::OrgGraphSettingsController < ApplicationController
  # GET /tenant/org_graph/settings
  def show
    authorize :org_graph, :edit_settings?
    render Views::Tenant::OrgGraph::SettingsView.new(
      editors: Operations::OrgGraph::Editors.call(context: pundit_user, params: {}),
      editor_candidates: editor_candidates,
      user: current_user,
      current_tenant: ActsAsTenant.current_tenant,
      tenants: ActsAsTenant.without_tenant { current_user.tenants.to_a }
    )
  end

  private

  # Members still in the organisation who aren't editors yet.
  #
  # @return [Array<Person>]
  def editor_candidates
    Person.where(status: "active", id: TenantUser.where(role: :member, org_graph_editor: false).select(:person_id))
          .order(:name).to_a
  end
end
