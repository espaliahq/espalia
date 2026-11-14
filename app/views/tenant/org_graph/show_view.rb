# frozen_string_literal: true

# The Org Graph's Units view (#80): the unit tree beside the unit it opens,
# its sub-units as cards of members, and the people in no team below.
#
# A drawer and a sidebar each have a slot. The controller hands in whichever
# a request opens, already wrapped in Drawer or Sidebar chrome, so each
# screen story builds its own component and leaves this file alone. Compare
# with a date (#139) hands in a bar for under the heading, and a comparison
# the tree and the cards mark.
class Views::Tenant::OrgGraph::ShowView < Views::Base
  # @param overview [OrgGraph::UnitsOverview]
  # @param user [User]
  # @param current_tenant [Tenant]
  # @param tenants [Array<Tenant>]
  # @param drawer [Phlex::SGML, nil] a component that renders a Drawer
  # @param sidebar [Phlex::SGML, nil] a component that renders a Sidebar
  # @param comparison_bar [Phlex::SGML, nil] the comparison's controls and counts
  # @param comparison [OrgGraph::Comparison]
  def initialize(overview:, user:, current_tenant:, tenants: [], drawer: nil, sidebar: nil,
                 comparison_bar: nil, comparison: OrgGraph::Comparison::NONE)
    @overview = overview
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
    @drawer = drawer
    @sidebar = sidebar
    @comparison_bar = comparison_bar
    @comparison = comparison
  end

  def view_template
    render Components::Shell::TenantAdminLayout.new(
      active_section: :org_graph,
      user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      # From `lg` up the drawer sits over the right of the page, so the page
      # makes room for it rather than hiding the cards beneath.
      div(class: ("lg:pr-[30rem]" if @drawer)) do
        render Components::Kit::SectionHeading.new(
          "Org Graph",
          subtitle: "Units and who is in each, as the Org Graph knows them today. Open a unit to change it."
        ) do |heading|
          heading.action do
            render Components::Kit::Button.new(variant: :outline, tone: :neutral, size: :sm, href: tenant_org_graph_settings_path) { "Settings" }
          end
        end
        render @comparison_bar if @comparison_bar

        if @overview.any_units?
          div(class: "mt-6 flex flex-col lg:flex-row gap-6") do
            render Views::Tenant::OrgGraph::UnitTree.new(overview: @overview, tray_id: Views::Tenant::OrgGraph::Tray::ID,
                                                             comparison: @comparison)
            div(class: "flex-1 min-w-0 space-y-6") do
              render Views::Tenant::OrgGraph::UnitPanel.new(overview: @overview, comparison: @comparison)
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
      end

      render @drawer if @drawer
    end
  end

  private

  def tray = render(Views::Tenant::OrgGraph::Tray.new(people: @overview.unplaced, unit_id: @overview.selected&.id))
end
