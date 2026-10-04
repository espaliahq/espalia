# frozen_string_literal: true

# Tenant administration dashboard: tiles linking to the admin sections.
# Sidebar navigation lives in {Components::Kit::TenantAdminLayout}.
#
class Views::Tenant::Dashboard::ShowView < Views::Base
  include Phlex::Rails::Helpers::Routes

  # Each tile resolves its href via the corresponding Rails route helper
  # at render time so changes to `config/routes.rb` flow through without
  # touching this list.
  TILES = [
    {
      label: "Theme",
      path: :tenant_theme_path,
      description: "Brand colors and typography for this tenant."
    },
    {
      label: "Users",
      path: :tenant_users_path,
      description: "Manage tenant memberships and framework collaborator roles."
    },
    {
      label: "Integrations",
      path: :tenant_integrations_path,
      description: "HRIS sync and other external systems."
    },
    {
      label: "Feedback export",
      path: :new_tenant_feedback_export_path,
      description: "Download a cycle's feedback as a CSV file for reporting."
    }
  ].freeze

  # @param user [User]
  # @param current_tenant [Tenant]
  # @param tenants [Array<Tenant>]
  def initialize(user:, current_tenant:, tenants: [])
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Kit::TenantAdminLayout.new(
      active_section: :dashboard,
      user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      render Components::Kit::SectionHeading.new(
        "Tenant administration",
        subtitle: "Manage settings for #{@current_tenant.name}."
      )
      tile_grid
    end
  end

  private

  def tile_grid
    div(class: "grid gap-4 sm:grid-cols-2 lg:grid-cols-3") do
      TILES.each { |tile| tile_card(tile) }
    end
  end

  def tile_card(tile)
    a(
      href: public_send(tile[:path]),
      class: "block bg-white dark:bg-gray-800 rounded-lg shadow-xs border " \
             "border-gray-200 dark:border-gray-700 p-5 " \
             "hover:border-primary hover:shadow-sm transition"
    ) do
      h3(class: "text-base font-semibold text-gray-900 dark:text-white") { tile[:label] }
      p(class: "mt-1 text-sm text-gray-600 dark:text-gray-300") { tile[:description] }
    end
  end
end
