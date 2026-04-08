# frozen_string_literal: true

# Lists every integration available to the current tenant.
#
# Currently surfaces the HRIS integration only — additional integration
# types (Slack, notifications, SSO) will appear here as they're built.
#
class Views::Integrations::IndexView < Views::Base
  # @param hris_config [HrisConfig]
  # @param hris_credentials_present [Boolean]
  # @param user [User, nil]
  # @param current_tenant [Tenant, nil]
  # @param tenants [Array<Tenant>]
  def initialize(hris_config:, hris_credentials_present:, user: nil, current_tenant: nil, tenants: [])
    @hris_config = hris_config
    @hris_credentials_present = hris_credentials_present
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Kit::PageLayout.new(
      user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      div(class: "max-w-5xl mx-auto px-4 py-8") do
        page_header
        integration_grid
      end
    end
  end

  private

  def page_header
    render Components::Kit::SectionHeading.new(
      "Integrations",
      subtitle: "Manage external systems connected to this workspace"
    )
  end

  def integration_grid
    div(class: "grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6") do
      hris_card
    end
  end

  def hris_card
    a(href: integration_path("hris"), class: "block group") do
      render Components::Kit::Card.new do |card|
        card.body do
          div(class: "flex items-start justify-between") do
            div do
              h3(class: "text-lg font-semibold text-gray-900 dark:text-white " \
                        "group-hover:text-primary transition-colors") { "HRIS" }
              p(class: "mt-1 text-sm text-gray-500 dark:text-gray-400") do
                plain provider_label
              end
            end
            render Components::Kit::Badge.new(status_label, variant: status_variant)
          end

          div(class: "mt-4 text-xs text-gray-500 dark:text-gray-400") do
            plain "Last synced: #{last_synced_label}"
          end
        end
      end
    end
  end

  def provider_label
    return "Not configured" if @hris_config.provider.blank?

    @hris_config.provider.humanize
  end

  def status_label
    return "Not configured" if @hris_config.provider.blank?
    return "Missing credentials" unless @hris_credentials_present
    return "Disabled" unless @hris_config.sync_enabled?

    "Active"
  end

  def status_variant
    return :default if @hris_config.provider.blank?
    return :warning unless @hris_credentials_present
    return :default unless @hris_config.sync_enabled?

    :success
  end

  def last_synced_label
    @hris_config.last_synced_at&.to_fs(:long) || "Never"
  end
end
