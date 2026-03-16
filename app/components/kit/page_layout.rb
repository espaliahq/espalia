# frozen_string_literal: true

# Shared page layout composing Navbar and main content area.
#
# On desktop: nav links are in the top Navbar, main content gets full width.
# On mobile: hamburger opens a Sidebar drawer overlay.
#
# @example
#   render Components::Kit::PageLayout.new(user: current_user, current_tenant: tenant, tenants: tenants) do
#     h1 { "Page Title" }
#   end
#
class Components::Kit::PageLayout < Components::Base
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
        links: nav_links,
        user: @user,
        current_tenant: @current_tenant,
        tenants: @tenants
      )

      # Mobile-only sidebar drawer
      render Components::Kit::Sidebar.new(links: nav_links)

      main(class: "flex-1 p-6 overflow-auto", &block)
    end
  end

  private

  # Builds nav links, adjusting the Framework link based on count.
  # When exactly one framework exists, links directly to it with singular label.
  #
  # @return [Array<Hash>]
  def nav_links
    @nav_links ||= [
      { label: "Home", href: "/" },
      framework_nav_link
    ]
  end

  def framework_nav_link
    frameworks = FrameworkState::Framework.all
    if frameworks.size == 1
      { label: "Framework", href: "/frameworks/#{frameworks.first.framework_id}" }
    else
      { label: "Frameworks", href: "/frameworks" }
    end
  end
end
