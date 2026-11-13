# frozen_string_literal: true

# The field preview on a page of its own, until the HRIS settings screen (6.9)
# hosts its frame.
class Views::Integrations::HrisFieldPreviewView < Views::Base
  # @param frame [Views::Integrations::HrisFieldPreviewFrame]
  # @param user [User]
  # @param current_tenant [Tenant]
  # @param tenants [Array<Tenant>]
  def initialize(frame:, user:, current_tenant:, tenants:)
    @frame = frame
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Shell::TenantAdminLayout.new(
      active_section: :integrations, user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      div(class: "max-w-4xl mx-auto space-y-6") do
        div do
          a(href: tenant_integration_path("hris"), class: "text-sm text-muted hover:text-default transition-colors") do
            plain "← Back to HRIS"
          end
          h1(class: "mt-2 text-2xl font-bold text-default") { "Preview an HRIS field" }
        end
        render(Components::Kit::Card.new) { |card| card.body { render @frame } }
      end
    end
  end
end
