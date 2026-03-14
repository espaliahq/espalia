# frozen_string_literal: true

# Top navigation bar with brand name and mobile hamburger toggle.
#
# @example
#   render Components::Kit::Navbar.new(
#     app_name: "GrowthOS",
#     user: current_user,
#     current_tenant: ActsAsTenant.current_tenant,
#     tenants: current_user.tenants
#   )
class Components::Kit::Navbar < Components::Base
  # @param app_name [String] The application name displayed in the navbar
  # @param user [User, nil] The currently signed-in user
  # @param current_tenant [Tenant, nil] The active tenant
  # @param tenants [Array<Tenant>] All tenants the user belongs to
  def initialize(app_name:, user: nil, current_tenant: nil, tenants: [])
    @app_name = app_name
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    nav(class: "flex items-center justify-between h-16 px-4 bg-nav-bg text-nav-fg shadow-sm shrink-0") do
      left_section
      right_section
    end
  end

  private

  def left_section
    div(class: "flex items-center gap-3") do
      hamburger_button
      span(class: "text-lg font-bold tracking-tight") { "#{@current_tenant&.name} #{@app_name}" }
    end
  end

  def hamburger_button
    button(
      type: "button",
      aria: { label: "Toggle navigation", expanded: "false" },
      class: "md:hidden p-1.5 rounded-md hover:bg-white/10 focus:outline-hidden focus:ring-2 focus:ring-white",
      data: { action: "sidebar#toggle" }
    ) do
      svg(
        xmlns: "http://www.w3.org/2000/svg",
        class: "h-6 w-6",
        fill: "none",
        viewBox: "0 0 24 24",
        stroke: "currentColor",
        aria: { hidden: "true" }
      ) do |s|
        s.path(
          stroke_linecap: "round",
          stroke_linejoin: "round",
          stroke_width: "2",
          d: "M4 6h16M4 12h16M4 18h16"
        )
      end
    end
  end

  def right_section
    div(class: "flex items-center gap-2") do
      if @user
        render Components::Kit::UserMenu.new(
          user: @user,
          current_tenant: @current_tenant,
          tenants: @tenants
        )
      else
        div(class: "h-8 w-8 rounded-full bg-white/20 flex items-center justify-center text-sm font-medium") do
          plain "U"
        end
      end
    end
  end
end
