# frozen_string_literal: true

# The tenant's approved headcount budget, a row per line, and the form that
# adds one. Every plan's scenarios start from these lines.
class Views::Tenant::BudgetLines::IndexView < Views::Base
  include Views::Tenant::OrgGraph::Settings::FormHelpers
  include Views::Tenant::BudgetLines::LineText
  include Views::Tenant::BudgetLines::LineFields

  # @param lines [Array<Hash>] as Operations::Tenants::BudgetLines lists them
  # @param roles [Array<FrameworkState::Role>] with their levels, for the role picker
  # @param countries [Array<String>] the countries the Org Graph holds
  # @param draft [Hash] what a refused form held, to show again
  # @param user [User]
  # @param current_tenant [Tenant]
  # @param tenants [Array<Tenant>]
  def initialize(lines:, roles:, countries:, draft: {}, user:, current_tenant:, tenants: [])
    @lines = lines
    @roles = roles
    @countries = countries
    @draft = draft
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Shell::TenantAdminLayout.new(
      active_section: :budget, user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      render Components::Kit::SectionHeading.new(
        "Budget", tag: :h1,
        subtitle: "The approved headcount budget. Every plan starts from it and may change or cut a line for itself. " \
                  "Only tenant admins see this page."
      ) do |heading|
        heading.action do
          render Components::Kit::Button.new(variant: :outline, tone: :neutral, size: :sm,
                                             href: tenant_planning_inputs_history_path("budget_lines")) { "History" }
        end
      end
      div(class: "space-y-6") do
        lines_card
        add_card
      end
    end
  end

  private

  def lines_card
    if @lines.empty?
      render Components::Kit::EmptyState.new(title: "No budget lines yet", size: :page) do
        plain "Add a line below for each approval: an amount, a head count or both."
      end
      return
    end

    render Components::Kit::Card.new(title: "Approved lines", heading_level: :h2, id: "budget-lines") do |card|
      card.body { ul(class: "divide-y divide-default") { @lines.each { line_row(it) } } }
    end
  end

  def line_row(line)
    id = line[:budget_line_id]
    li(id: "budget-line-#{id}", class: "py-3 first:pt-0 last:pb-0") do
      div(class: "flex flex-wrap items-start justify-between gap-x-4 gap-y-2") do
        div(class: "min-w-0") do
          p(class: "text-sm font-medium text-default") { line_name(line) }
          p(class: "text-sm text-default") { figures_text(line) }
          p(class: "text-xs text-muted") { terms_text(line) }
          p(class: "text-xs text-muted") { changed_text(line) }
        end
        div(class: "flex shrink-0 items-center gap-2") do
          render Components::Kit::Button.new(variant: :outline, tone: :neutral, size: :sm, href: edit_tenant_budget_line_path(id),
                                             id: "budget-line-change-#{id}", aria_label: "Change the line for #{line_name(line)}") { "Change" }
          line_menu(line)
        end
      end
    end
  end

  # Remove is destructive, so it sits in the row's kebab, which opens the dialog.
  def line_menu(line)
    id = line[:budget_line_id]
    render Components::Kit::Modal.new(id: "budget-line-remove-#{id}", title: "Remove the line for #{line_name(line)}?", size: :sm) do |modal|
      render Components::Kit::Dropdown.new(align: :right, strategy: :fixed) do |menu|
        menu.trigger(label: "Actions for the line for #{line_name(line)}",
                     button: { variant: :ghost, size: :sm, icon: true, compact: true, id: "budget-line-menu-#{id}" }) do
          icon(:kebab, class: "size-4")
        end
        menu.menu(width: "w-44") do
          menu.item(tone: :danger, data: { action: "modal#open" }, id: "budget-line-remove-item-#{id}") { "Remove the line" }
        end
      end
      modal.body { remove_form(id) }
    end
  end

  def remove_form(id)
    p(class: "text-sm text-default") do
      "Plans no longer start from this line. A plan that changed or cut it keeps its change, and Attention flags it there."
    end
    settings_form(tenant_budget_line_path(id), method: :delete, class: "mt-4 flex justify-end gap-2") do
      render Components::Kit::Button.new(variant: :outline, tone: :neutral, data: { action: "modal#close" }) { "Cancel" }
      render Components::Kit::Button.new(tone: :danger, type: :submit, id: "budget-line-remove-confirm-#{id}") { "Remove the line" }
    end
  end

  def add_card
    render Components::Kit::Card.new(title: "Add a line", heading_level: :h2, id: "budget-lines-add") do |card|
      card.body do
        settings_form(tenant_budget_lines_path, class: "space-y-4") do
          line_fields(@draft, roles: @roles, countries: @countries)
          div(class: "flex justify-end") do
            render Components::Kit::Button.new(type: :submit, id: "budget-line-add") { "Add the line" }
          end
        end
      end
    end
  end
end
