# frozen_string_literal: true

# The tenant's cost-centre entries as one ordered list, and the form that adds
# one. A seat with no cost centre of its own takes the last entry in the list
# that matches it ([#387](https://github.com/espaliahq/espalia/issues/387)),
# so the order is the precedence, as for pay bands.
class Views::Tenant::CostCentreRules::IndexView < Views::Base
  include Views::Tenant::OrgGraph::Settings::FormHelpers
  include Views::Tenant::CostCentreRules::EntryFields

  GONE = "No longer there"
  SHADOWED = "Never used"
  MOVE_FORM = "cost-centre-entries-move-form"

  # @param entries [Array<Hash>] the tenant's entries, in order
  # @param shadowed [Set<Integer>] the indexes of the entries a later one always overrides
  # @param rule [Hash] the cost_centre rule as Operations::Tenants::PlanningRules lists it
  # @param choices [Views::Tenant::CostCentreRules::EntryFields::Choices]
  # @param draft [Hash] what a refused form held, to show again
  # @param user [User]
  # @param current_tenant [Tenant]
  # @param tenants [Array<Tenant>]
  def initialize(entries:, shadowed:, rule:, choices:, draft: {}, user:, current_tenant:, tenants: [])
    @entries = entries
    @shadowed = shadowed
    @rule = rule
    @choices = choices
    @draft = draft
    @version = Views::Tenant::CostCentreRules::EntryFields.version(entries)
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Shell::TenantAdminLayout.new(
      active_section: :cost_centres, user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      render Components::Kit::SectionHeading.new(
        "Cost centres", tag: :h1,
        subtitle: "Which cost centre a plan puts a seat in when nothing more certain decides. Only tenant admins see this page."
      )
      div(class: "max-w-3xl space-y-6") do
        @entries.empty? ? empty_state : order_card
        add_card
      end
    end
  end

  private

  def empty_state
    render Components::Kit::EmptyState.new(title: "No cost-centre entries yet", size: :page) do
      plain "Add an entry below. Until then, a seat with no cost centre of its own has none in a plan."
    end
  end

  def order_card
    render Components::Kit::Card.new(title: "The order", heading_level: :h2, id: "cost-centre-entries") do |card|
      card.body do
        div(class: "space-y-2 text-sm text-muted") do
          p do
            plain "Every entry that matches a seat applies, so the last one in this list has the last word. " \
                  "Put wide entries first and narrow ones after."
          end
          p do
            plain "A position's own cost centre comes first. A person keeps their real one unless a plan changes their " \
                  "unit, role, level or country, even in a labelled position. A plan can set its own list instead."
          end
          p { updated_text } if @rule[:updated_at]
        end
        div(data: { controller: "drag-order", drag_order_field_value: "entry_ids" }) do
          settings_form(reorder_tenant_cost_centre_rules_path, method: :patch, id: "cost-centre-entries-reorder-form", hidden: true,
                                                               data: { drag_order_target: "form" }) { version_field }
          settings_form(reorder_tenant_cost_centre_rules_path, method: :patch, id: MOVE_FORM, hidden: true) { version_field }
          ol(class: "mt-4 divide-y divide-default", data: { drag_order_target: "list" }) do
            @entries.each_with_index { |entry, index| entry_row(entry, index) }
          end
        end
      end
    end
  end

  def updated_text
    at = Time.zone.parse(@rule[:updated_at]).to_date.to_fs(:long)
    @rule[:updated_by] ? "Last changed by #{@rule[:updated_by]} on #{at}." : "Last changed on #{at}."
  end

  def version_field = input(type: "hidden", name: "version", value: @version)

  def entry_row(entry, index)
    place = index + 1
    li(id: "cost-centre-entry-#{place}", class: "py-3 first:pt-0 last:pb-0 pointer-fine:cursor-grab data-[drag-source]:opacity-50",
       draggable: "true",
       data: { order_id: place,
               action: "pointerdown->drag-order#press dragstart->drag-order#start dragover->drag-order#over " \
                       "drop->drag-order#drop dragend->drag-order#end" }) do
      div(class: "flex items-start gap-3") do
        span(class: "mt-0.5 w-6 shrink-0 text-right text-sm font-medium tabular-nums text-muted") { "#{place}." }
        div(class: "flex min-w-0 flex-1 flex-col gap-2 sm:flex-row sm:items-start sm:justify-between sm:gap-4") do
          entry_text(entry, index)
          div(class: "flex shrink-0 items-center gap-2") do
            move_buttons(entry, index)
            render Components::Kit::Button.new(variant: :outline, tone: :neutral, size: :sm,
                                               href: edit_tenant_cost_centre_rule_path(place, version: @version),
                                               id: "cost-centre-entry-change-#{place}",
                                               aria_label: "Change entry #{place}, #{entry['cost_centre']}") { "Change" }
            entry_menu(entry, place)
          end
        end
      end
    end
  end

  def entry_text(entry, index)
    div(class: "min-w-0 flex-1") do
      p(class: "flex flex-wrap items-center gap-2 text-sm font-medium text-default") do
        span { entry["cost_centre"] }
        render Components::Kit::Badge.new(GONE, tone: :neutral) if gone?(entry)
        render Components::Kit::Badge.new(SHADOWED, tone: :warning, id: "cost-centre-entry-shadowed-#{index + 1}") if @shadowed.include?(index)
      end
      p(class: "text-sm text-default break-words") { matcher_text(entry) }
      if @shadowed.include?(index)
        p(class: "text-sm text-muted") { "An entry below it matches every seat this one does, so plans never use it. Move it down, or remove it." }
      end
    end
  end

  def move_buttons(entry, index)
    div(class: "flex items-center gap-1") do
      move_button(entry, index, index.positive?, "up")
      move_button(entry, index, index < @entries.size - 1, "down")
    end
  end

  def move_button(entry, index, allowed, direction)
    return span(class: "size-8 shrink-0", aria: { hidden: "true" }) unless allowed

    render Components::Kit::Button.new(
      variant: :ghost, tone: :neutral, size: :sm, icon: true, compact: true, type: :submit, form: MOVE_FORM,
      formaction: reorder_tenant_cost_centre_rules_path(entry: index + 1, direction:),
      id: "cost-centre-entry-#{direction}-#{index + 1}", aria_label: "Move entry #{index + 1}, #{entry['cost_centre']}, #{direction}"
    ) { icon(:"chevron-#{direction}", class: "size-4") }
  end

  # Remove is destructive, so it sits in the row's kebab, which opens the dialog.
  def entry_menu(entry, place)
    render Components::Kit::Modal.new(id: "cost-centre-entry-remove-#{place}", title: "Remove entry #{place}, #{entry['cost_centre']}?",
                                      size: :sm) do |modal|
      render Components::Kit::Dropdown.new(align: :right, strategy: :fixed) do |menu|
        menu.trigger(label: "Actions for entry #{place}, #{entry['cost_centre']}",
                     button: { variant: :ghost, size: :sm, icon: true, compact: true, id: "cost-centre-entry-menu-#{place}" }) do
          icon(:kebab, class: "size-4")
        end
        menu.menu(width: "w-44") do
          menu.item(tone: :danger, data: { action: "modal#open" }, id: "cost-centre-entry-remove-item-#{place}") { "Remove the entry" }
        end
      end
      modal.body { remove_form(place) }
    end
  end

  def remove_form(place)
    p(class: "text-sm text-default") { "Plans then take each seat's cost centre from the last entry left that matches it, if there is one." }
    settings_form(tenant_cost_centre_rule_path(place), method: :delete, class: "mt-4 flex justify-end gap-2") do
      version_field
      render Components::Kit::Button.new(variant: :outline, tone: :neutral, data: { action: "modal#close" }) { "Cancel" }
      render Components::Kit::Button.new(tone: :danger, type: :submit, id: "cost-centre-entry-remove-confirm-#{place}") { "Remove the entry" }
    end
  end

  def add_card
    render Components::Kit::Card.new(title: "Add an entry", heading_level: :h2, id: "cost-centre-entries-add") do |card|
      card.body do
        settings_form(tenant_cost_centre_rules_path, class: "space-y-4") do
          version_field
          p(class: "text-sm text-muted") { "Name at least one of unit, who, level or country. It lands at the end of the list." }
          entry_fields(@draft)
          div(class: "flex justify-end") do
            render Components::Kit::Button.new(type: :submit, id: "cost-centre-entry-add") { "Add the entry" }
          end
        end
      end
    end
  end
end
