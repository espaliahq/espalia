# frozen_string_literal: true

# The Org Graph's Units view (#80): the unit tree beside the unit it opens,
# its sub-units as cards of members, and the people in no team below.
#
# A drawer and a sidebar each have a slot. The controller hands in whichever
# a request opens, already wrapped in Drawer or Sidebar chrome, so each
# screen story builds its own component and leaves this file alone.
class Views::Tenant::OrgGraph::ShowView < Views::Base
  # @param overview [OrgGraph::UnitsOverview]
  # @param user [User]
  # @param current_tenant [Tenant]
  # @param tenants [Array<Tenant>]
  # @param drawer [Phlex::SGML, nil] a component that renders a Drawer
  # @param sidebar [Phlex::SGML, nil] a component that renders a Sidebar
  def initialize(overview:, user:, current_tenant:, tenants: [], drawer: nil, sidebar: nil)
    @overview = overview
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
    @drawer = drawer
    @sidebar = sidebar
  end

  def view_template
    render Components::Shell::TenantAdminLayout.new(
      active_section: :org_graph,
      user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      render Components::Kit::SectionHeading.new(
        "Org Graph",
        subtitle: "Units and who is in each, as the Org Graph knows them today. Read-only for now."
      )

      if @overview.any_units?
        div(class: "mt-6 flex flex-col lg:flex-row gap-6") do
          render Views::Tenant::OrgGraph::UnitTree.new(overview: @overview, tray_id: Views::Tenant::OrgGraph::Tray::ID)
          div(class: "flex-1 min-w-0 space-y-6") do
            render Views::Tenant::OrgGraph::UnitPanel.new(overview: @overview)
            tray
          end
          render @sidebar if @sidebar
        end
      else
        div(class: "mt-6 flex flex-col lg:flex-row gap-6") do
          div(class: "flex-1 min-w-0 space-y-6") do
            render Components::Kit::EmptyState.new(title: "No units yet") do
              "Units appear here once the Org Graph holds the organisation's structure."
            end
            tray
          end
          render @sidebar if @sidebar
        end
      end

      render @drawer if @drawer
    end
  end

  private

  def tray = render(Views::Tenant::OrgGraph::Tray.new(people: @overview.unplaced))
end
