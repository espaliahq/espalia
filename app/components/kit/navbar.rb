# frozen_string_literal: true

# Top navigation bar with brand, nav links, and user menu.
#
# On desktop (md+): nav links are inline in the navbar.
# On mobile: hamburger button toggles the sidebar drawer.
#
# @example
#   render Components::Kit::Navbar.new(
#     app_name: "GrowthOS",
#     links: [{ label: "Home", href: "/" }],
#     user: current_user,
#     current_tenant: ActsAsTenant.current_tenant,
#     tenants: current_user.tenants
#   )
class Components::Kit::Navbar < Components::Base
  # @param app_name [String] The application name displayed in the navbar
  # @param links [Array<Hash>] Navigation links with :label and :href
  # @param user [User, nil] The currently signed-in user
  # @param current_tenant [Tenant, nil] The active tenant
  # @param tenants [Array<Tenant>] All tenants the user belongs to
  def initialize(app_name:, links: [], user: nil, current_tenant: nil, tenants: [])
    @app_name = app_name
    @links = links
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    nav(class: "flex items-center justify-between h-12 px-4 bg-nav-bg text-nav-fg shadow-xs shrink-0") do
      left_section
      right_section
    end
  end

  private

  def left_section
    div(class: "flex items-center gap-4") do
      hamburger_button
      span(class: "text-sm font-bold tracking-tight") do
        plain "#{@current_tenant&.name} #{@app_name}"
        if Rails.env.development?
          span(class: "ml-1 text-[10px] font-normal opacity-70") { "(#{Rails.root.basename})" }
        end
      end
      desktop_nav_links
    end
  end

  def hamburger_button
    button(
      type: "button",
      aria: { label: "Toggle navigation", expanded: "false" },
      class: "md:hidden inline-flex items-center justify-center h-11 w-11 -ml-1.5 rounded-md " \
             "hover:bg-white/10 focus:outline-hidden focus:ring-2 focus:ring-white",
      data: { action: "sidebar#toggle" }
    ) do
      svg(
        xmlns: "http://www.w3.org/2000/svg",
        class: "h-5 w-5",
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

  # Nav links visible on md+ screens, hidden on mobile
  def desktop_nav_links
    return if @links.empty?

    div(class: "hidden md:flex items-center gap-1 ml-2") do
      @links.each { |link| nav_link(link) }
    end
  end

  def nav_link(link)
    a(
      href: link[:href],
      class: "px-3 py-1.5 rounded-md text-sm font-medium " \
             "text-nav-fg/70 hover:text-nav-fg hover:bg-white/10 transition-colors"
    ) do
      plain link[:label]
    end
  end

  # Live-updating notification bell. The hidden signal element is replaced by a
  # per-user Turbo Stream when a notification lands; notifications_sync_controller
  # reloads the lazy bell frame in response. See Views::Notifications::Bell.
  def notification_bell
    div(data: { controller: "notifications-sync" }) do
      turbo_stream_from(@user, :notifications)
      div(id: "notifications-sync-signal", data: { notifications_sync_target: "signal" }, hidden: true)
      turbo_frame_tag("notification-bell", src: bell_notifications_path, loading: "lazy") do
        # Placeholder shown until the lazy frame resolves — keeps layout stable.
        div(class: "h-11 w-11", aria: { hidden: "true" })
      end
    end
  end

  def right_section
    div(class: "flex items-center gap-2") do
      if @user
        notification_bell
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
