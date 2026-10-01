# frozen_string_literal: true

# Tenant-administration shell. Wraps {Components::Kit::PageLayout}
# and renders a left sidebar listing the admin sections (Dashboard,
# Theme, Users, Integrations). The page view yields its content into
# the right-hand pane.
#
# Active section is supplied explicitly by the caller — the component
# does not infer it from the request path. Closed set of four sections
# for now; expand when a new admin surface lands.
#
# @example
#   render Components::Kit::TenantAdminLayout.new(
#     active_section: :theme,
#     user: current_user,
#     current_tenant: ActsAsTenant.current_tenant,
#     tenants: tenants_for_user
#   ) do
#     render Components::Kit::SectionHeading.new(title: "Theme")
#     # page content
#   end
#
class Components::Kit::TenantAdminLayout < Components::Base
  SECTIONS = [
    { key: :dashboard,    label: "Dashboard",    href: "/tenant" },
    { key: :theme,        label: "Theme",        href: "/tenant/theme" },
    { key: :vocabulary,   label: "Vocabulary",   href: "/tenant/vocabulary" },
    { key: :users,        label: "Users",        href: "/tenant/users" },
    { key: :integrations, label: "Integrations", href: "/tenant/integrations" }
  ].freeze

  # @param active_section [Symbol] one of :dashboard, :theme, :vocabulary,
  #   :users, :integrations
  # @param user [User]
  # @param current_tenant [Tenant]
  # @param tenants [Array<Tenant>]
  def initialize(active_section:, user:, current_tenant:, tenants: [])
    @active_section = active_section
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template(&block)
    render Components::Kit::PageLayout.new(
      user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      div(class: "flex flex-col md:flex-row gap-6") do
        render_sidebar
        div(class: "flex-1 min-w-0", &block)
      end
    end
  end

  private

  def render_sidebar
    aside(
      class: "md:w-56 md:shrink-0 md:sticky md:top-4 md:self-start",
      aria: { label: "Tenant administration sections" }
    ) do
      # Mobile: horizontal pill strip. Desktop: vertical list.
      nav(class: "flex md:flex-col gap-1 overflow-x-auto md:overflow-visible " \
                 "pb-2 md:pb-0") do
        SECTIONS.each { |section| sidebar_link(section) }
      end
    end
  end

  def sidebar_link(section)
    active = section[:key] == @active_section
    base = "px-3 py-2 rounded-md text-sm whitespace-nowrap transition-colors"
    state = if active
      "bg-primary/10 text-primary-ink font-semibold"
    else
      "text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-800"
    end

    a(
      href: section[:href],
      class: "#{base} #{state}",
      aria: { current: active ? "page" : nil }
    ) { section[:label] }
  end
end
