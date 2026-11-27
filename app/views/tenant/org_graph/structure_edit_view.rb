# frozen_string_literal: true

# One unit's own structure, on its own page ([#537](https://github.com/espaliahq/espalia/issues/537)):
# the unit types beneath it and where each can sit, for whoever may change them.
class Views::Tenant::OrgGraph::StructureEditView < Views::Base
  # @param structure [Hash] as Operations::OrgGraph::UnitStructure reads it
  # @param user [User]
  # @param current_tenant [Tenant]
  # @param viewer [OrgGraphPolicy::Viewer] the shell
  # @param tenants [Array<Tenant>]
  def initialize(structure:, user:, current_tenant:, viewer:, tenants: [])
    @structure = structure
    @user = user
    @current_tenant = current_tenant
    @viewer = viewer
    @tenants = tenants
  end

  def view_template
    shell do
      a(href: tenant_org_graph_path(unit: @structure[:unit_id]), class: "text-sm text-muted hover:text-default transition-colors") do
        "← Back to #{@structure[:name]}"
      end
      h1(class: "mt-2 text-2xl font-bold text-default") { "The structure beneath #{@structure[:name]}" }

      div(class: "mt-6 max-w-3xl") do
        render Views::Tenant::OrgGraph::Settings::LevelsPanel.new(
          hris: { connected: false }, levels: @structure[:levels], can_edit_taxonomy: true,
          structure: @structure.slice(:unit_id, :name), on_structure_page: true
        )
      end
    end
  end

  private

  def shell(&)
    if @viewer.admin?
      render(Components::Shell::TenantAdminLayout.new(active_section: :org_graph, user: @user, current_tenant: @current_tenant,
                                                      tenants: @tenants), &)
    else
      render(Components::Shell::PageLayout.new(user: @user, current_tenant: @current_tenant, tenants: @tenants), &)
    end
  end
end
