# frozen_string_literal: true

# Changes one cost-centre entry in place. Its place in the list changes
# through the list.
class Views::Tenant::CostCentreRules::EditView < Views::Base
  include Views::Tenant::OrgGraph::Settings::FormHelpers
  include Views::Tenant::CostCentreRules::EntryFields

  # @param place [Integer] the entry's index in the list
  # @param values [Hash{Symbol => String}] the entry as the form holds it, or what was typed
  # @param version [String] the version of the list the page showed
  # @param choices [Views::Tenant::CostCentreRules::EntryFields::Choices]
  # @param user [User]
  # @param current_tenant [Tenant]
  # @param tenants [Array<Tenant>]
  def initialize(place:, values:, version:, choices:, user:, current_tenant:, tenants: [])
    @place = place
    @values = values
    @version = version
    @choices = choices
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Shell::TenantAdminLayout.new(
      active_section: :cost_centres, user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      render Components::Kit::SectionHeading.new("Change a cost-centre entry", tag: :h1)
      div(class: "max-w-3xl") do
        render Components::Kit::Card.new(title: "Entry #{@place + 1}", heading_level: :h2, id: "cost-centre-entry-edit") do |card|
          card.body do
            settings_form(tenant_cost_centre_rule_path(@place + 1), method: :patch, class: "space-y-4") do
              input(type: "hidden", name: "version", value: @version)
              entry_fields(@values)
              div(class: "flex justify-end gap-2") do
                render Components::Kit::Button.new(variant: :outline, tone: :neutral, href: tenant_cost_centre_rules_path) { "Cancel" }
                render Components::Kit::Button.new(type: :submit, id: "cost-centre-entry-save") { "Save the entry" }
              end
            end
          end
        end
      end
    end
  end
end
