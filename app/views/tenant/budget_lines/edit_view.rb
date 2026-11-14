# frozen_string_literal: true

# Changes one line of the approved budget. Every plan reads the budget live,
# so each sees the change at once.
class Views::Tenant::BudgetLines::EditView < Views::Base
  include Views::Tenant::OrgGraph::Settings::FormHelpers
  include Views::Tenant::BudgetLines::LineText
  include Views::Tenant::BudgetLines::LineFields

  # @param line [Hash] as Operations::Tenants::BudgetLines lists it, with any typed values merged in
  # @param roles [Array<FrameworkState::Role>] with their levels
  # @param countries [Array<String>]
  # @param user [User]
  # @param current_tenant [Tenant]
  # @param tenants [Array<Tenant>]
  def initialize(line:, roles:, countries:, user:, current_tenant:, tenants: [])
    @line = line
    @roles = roles
    @countries = countries
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Shell::TenantAdminLayout.new(
      active_section: :budget, user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      render Components::Kit::SectionHeading.new("Change a budget line", tag: :h1, subtitle: changed_text(@line))
      render Components::Kit::Card.new(title: line_name(@line), heading_level: :h2, id: "budget-line-edit") do |card|
        card.body do
          settings_form(tenant_budget_line_path(@line[:budget_line_id]), method: :patch, class: "space-y-4") do
            p(class: "text-sm text-muted") { "Every plan that starts from this line sees the change at once." }
            line_fields(@line, roles: @roles, countries: @countries)
            div(class: "flex justify-end gap-2") do
              render Components::Kit::Button.new(variant: :outline, tone: :neutral, href: tenant_budget_lines_path) { "Cancel" }
              render Components::Kit::Button.new(type: :submit, id: "budget-line-save") { "Save the line" }
            end
          end
        end
      end
    end
  end
end
