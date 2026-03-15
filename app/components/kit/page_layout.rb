# frozen_string_literal: true

# Shared page layout composing Navbar, Sidebar, and main content area.
#
# Provides the responsive shell used by all authenticated pages.
# Yields the main content block.
#
# @example
#   render Components::Kit::PageLayout.new(user: current_user, current_tenant: tenant, tenants: tenants) do
#     h1 { "Page Title" }
#   end
#
class Components::Kit::PageLayout < Components::Base
  NAV_LINKS = [
    { label: "Home", href: "/" },
    { label: "Frameworks", href: "/frameworks" }
  ].freeze

  # @param user [User, nil] the currently signed-in user
  # @param current_tenant [Tenant, nil] the active tenant
  # @param tenants [Array<Tenant>] all tenants the user belongs to
  def initialize(user: nil, current_tenant: nil, tenants: [])
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template(&block)
    div(
      class: "min-h-screen flex flex-col bg-gray-50 dark:bg-gray-950",
      data: { controller: "sidebar" }
    ) do
      render Components::Kit::Navbar.new(
        app_name: "GrowthOS",
        user: @user,
        current_tenant: @current_tenant,
        tenants: @tenants
      )

      div(class: "flex flex-1") do
        render Components::Kit::Sidebar.new(links: NAV_LINKS)
        main(class: "flex-1 p-6 overflow-auto", &block)
      end
    end
  end
end
