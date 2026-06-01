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
    render Components::Kit::Dropdown.new(align: :right) do |dropdown|
      dropdown.trigger { avatar_circle }
      dropdown.menu { menu_content }
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
    sign_out_link
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
      class: "w-4 h-4 shrink-0 text-primary",
      fill: "none",
      viewBox: "0 0 24 24",
      stroke: "currentColor",
      stroke_width: "2"
    ) do |s|
      s.path(stroke_linecap: "round", stroke_linejoin: "round", d: "M5 13l4 4L19 7")
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
