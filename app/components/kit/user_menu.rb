# frozen_string_literal: true

# User dropdown menu for the navbar.
#
# Shows the user's initial as a trigger and renders a dropdown with:
# - User email (header)
# - Tenant switcher (only when user belongs to multiple tenants)
# - Sign out link
#
# @example
#   render Components::Kit::UserMenu.new(
#     user: current_user,
#     current_tenant: ActsAsTenant.current_tenant,
#     tenants: current_user.tenants
#   )
class Components::Kit::UserMenu < Components::Base
  # @param user [User] the currently signed-in user
  # @param current_tenant [Tenant, nil] the active tenant
  # @param tenants [Array<Tenant>] all tenants the user belongs to
  def initialize(user:, current_tenant:, tenants: [])
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    # Wrapper id lets tests scope to this dropdown specifically — the navbar now
    # also hosts the notification bell dropdown.
    div(id: "user-menu", class: "inline-block") do
      render Components::Kit::Dropdown.new(align: :right) do |dropdown|
        # Two tones, because the nav colour is the tenant's: whichever of the
        # ring and the dark band behind it contrasts with their navbar carries.
        dropdown.trigger(focus_ring: "rounded-full focus-visible:ring-nav-fg " \
                                     "focus-visible:ring-offset-2 focus-visible:ring-offset-gray-900") { avatar_circle }
        dropdown.menu { menu_content }
      end
    end
  end

  private

  # @return [String] the first character of the user's email, uppercased
  def user_initial
    @user.email.chr.upcase
  end

  # Wraps the 32px avatar in a 44x44 target so the touch/click area meets
  # WCAG 2.5.5 (Target Size) while keeping the circle's visual size.
  def avatar_circle
    div(class: "flex items-center justify-center h-11 w-11 cursor-pointer") do
      div(
        class: "h-8 w-8 rounded-full bg-nav-fg/20 flex items-center justify-center " \
               "text-sm font-medium text-nav-fg hover:bg-nav-fg/30 transition-colors"
      ) do
        plain user_initial
      end
    end
  end

  def menu_content
    email_header
    tenant_section if @tenants.size > 1
    divider
    notifications_link
    ai_assistants_link
    sign_out_link
  end

  def notifications_link
    a(
      href: settings_notifications_path,
      class: "flex items-center gap-2 px-4 py-2 text-sm text-gray-700 dark:text-gray-200 " \
             "hover:bg-gray-100 dark:hover:bg-gray-700",
      role: "menuitem"
    ) do
      svg(xmlns: "http://www.w3.org/2000/svg", class: "h-4 w-4", fill: "none",
          viewBox: "0 0 24 24", stroke: "currentColor", aria: { hidden: "true" }) do |s|
        s.path(stroke_linecap: "round", stroke_linejoin: "round", stroke_width: "2",
               d: "M15 17h5l-1.405-1.405A2.032 2.032 0 0118 14.158V11a6.002 6.002 0 00-4-5.659V5a2 2 0 10-4 0v.341C7.67 6.165 6 8.388 6 11v3.159c0 .538-.214 1.055-.595 1.436L4 17h5m6 0v1a3 3 0 11-6 0v-1m6 0H9")
      end
      span { "Notifications" }
    end
  end

  def email_header
    div(class: "px-4 py-2") do
      p(class: "text-sm font-medium text-gray-900 dark:text-white truncate") { @user.email }
      if @current_tenant
        p(class: "text-xs text-gray-600 dark:text-gray-300 truncate") { @current_tenant.name }
      end
    end
  end

  def tenant_section
    divider
    div(class: "px-4 py-1.5") do
      p(class: "text-xs font-semibold text-gray-600 dark:text-gray-300 uppercase tracking-wider") do
        plain "Switch workspace"
      end
    end
    @tenants.each { |tenant| tenant_item(tenant) }
  end

  def tenant_item(tenant)
    current = @current_tenant&.id == tenant.id

    if current
      div(
        class: "flex items-center gap-2 px-4 py-2 text-sm text-gray-700 dark:text-gray-200 bg-gray-50 dark:bg-gray-700/50",
        role: "menuitem"
      ) do
        checkmark_icon
        span(class: "font-medium truncate") { tenant.name }
      end
    else
      form(
        action: users_tenant_switch_path,
        method: :post,
        role: "none"
      ) do
        input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
        input(type: "hidden", name: "tenant_id", value: tenant.id)
        button(
          type: "submit",
          class: "flex items-center gap-2 w-full px-4 py-2 text-sm text-gray-700 dark:text-gray-200 " \
                 "hover:bg-gray-100 dark:hover:bg-gray-700 text-left",
          role: "menuitem"
        ) do
          # Empty space to align with checkmark
          span(class: "w-4 h-4 shrink-0")
          span(class: "truncate") { tenant.name }
        end
      end
    end
  end

  def ai_assistants_link
    a(
      href: settings_connected_clients_path,
      class: "flex items-center gap-2 px-4 py-2 text-sm text-gray-700 dark:text-gray-200 " \
             "hover:bg-gray-100 dark:hover:bg-gray-700",
      role: "menuitem"
    ) do
      ai_assistants_icon
      span { "AI assistants" }
    end
  end

  def sign_out_link
    a(
      href: destroy_user_session_path,
      data: { turbo_method: :delete },
      class: "flex items-center gap-2 px-4 py-2 text-sm text-gray-700 dark:text-gray-200 " \
             "hover:bg-gray-100 dark:hover:bg-gray-700",
      role: "menuitem"
    ) do
      sign_out_icon
      span { "Sign out" }
    end
  end

  def divider
    div(class: "border-t border-gray-200 dark:border-gray-700 my-1")
  end

  def checkmark_icon
    svg(
      xmlns: "http://www.w3.org/2000/svg",
      class: "w-4 h-4 shrink-0 text-primary-ink",
      fill: "none",
      viewBox: "0 0 24 24",
      stroke: "currentColor",
      stroke_width: "2"
    ) do |s|
      s.path(stroke_linecap: "round", stroke_linejoin: "round", d: "M5 13l4 4L19 7")
    end
  end

  def ai_assistants_icon
    svg(
      xmlns: "http://www.w3.org/2000/svg",
      class: "w-4 h-4 shrink-0 text-gray-400",
      fill: "none",
      viewBox: "0 0 24 24",
      stroke: "currentColor",
      stroke_width: "2",
      aria: { hidden: "true" }
    ) do |s|
      s.path(
        stroke_linecap: "round",
        stroke_linejoin: "round",
        d: "M9 3v2m6-2v2M9 19v2m6-2v2M5 9H3m2 6H3m18-6h-2m2 6h-2M7 7h10a2 2 0 012 2v6a2 2 0 01-2 2H7a2 2 0 01-2-2V9a2 2 0 012-2z"
      )
    end
  end

  def sign_out_icon
    svg(
      xmlns: "http://www.w3.org/2000/svg",
      class: "w-4 h-4 shrink-0 text-gray-400",
      fill: "none",
      viewBox: "0 0 24 24",
      stroke: "currentColor",
      stroke_width: "2"
    ) do |s|
      s.path(
        stroke_linecap: "round",
        stroke_linejoin: "round",
        d: "M17 16l4-4m0 0l-4-4m4 4H7m6 4v1a3 3 0 01-3 3H6a3 3 0 01-3-3V7a3 3 0 013-3h4a3 3 0 013 3v1"
      )
    end
  end
end
