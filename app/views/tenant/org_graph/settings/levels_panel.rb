# frozen_string_literal: true

# "Unit types": the structure's unit types, who supplies each, and where each
# can sit. An admin ticks the types each one can sit under, and whether it can
# sit at the top. An empty type can be read from an HRIS field, or handed back
# to Espalia, here; one that holds units changes hands through the handover.
# An admin adds a type, and removes one Sources says can go today.
#
# A unit with a structure of its own ([#494](https://github.com/espaliahq/espalia/issues/494)) gets a panel of its own, whose
# writes name that unit. Its types are Espalia's, so it has no HRIS pickers.
class Views::Tenant::OrgGraph::Settings::LevelsPanel < Views::Base
  include Views::Tenant::OrgGraph::Settings::FormHelpers

  ESPALIA = OrgGraph::StructureAggregate::ESPALIA

  # The field picker for one level.
  #
  # @param level_id [String]
  # @param name [String]
  # @return [Views::Tenant::OrgGraph::Settings::FieldPickerFrame::Picker]
  def self.picker(level_id, name)
    routes = Rails.application.routes.url_helpers
    Views::Tenant::OrgGraph::Settings::FieldPickerFrame::Picker.new(
      key: "level-#{level_id}", target: Integrations::HrisFieldPreview::LEVEL, label: "HRIS field for #{name}",
      url: routes.tenant_org_graph_settings_level_field_path(level_id),
      use_url: routes.tenant_org_graph_settings_level_provider_path(level_id), field_param: "field",
      in_use: "#{name} is read from this field now."
    )
  end

  # @param hris [Hash] provider, label and connected, as Operations::OrgGraph::Sources reads them
  # @param levels [Array<Hash>] each level as Operations::OrgGraph::Sources reads it, top first
  # @param can_edit_taxonomy [Boolean] whether the viewer may add and remove unit types, and set where each can sit
  # @param structure [Hash, nil] `{ unit_id, name }` of the unit whose own structure this is; nil for the top one
  # @param on_structure_page [Boolean] whether its writes land back on the structure's own page, not Settings
  def initialize(hris:, levels:, can_edit_taxonomy: false, structure: nil, on_structure_page: false)
    @hris = hris
    @levels = levels
    @can_edit_taxonomy = can_edit_taxonomy
    @structure = structure
    @on_structure_page = on_structure_page
  end

  # @param structure_unit_id [String, nil]
  # @return [String] the panel's id, which a write lands back on
  def self.anchor(structure_unit_id) = structure_unit_id ? "org-graph-levels-#{structure_unit_id}" : "org-graph-levels"

  def view_template
    render Components::Kit::Card.new(title:, heading_level: :h2, id: self.class.anchor(@structure&.dig(:unit_id))) do |card|
      card.body do
        p(class: "text-sm text-muted") { intro }
        if @levels.empty?
          p(class: "mt-4 text-sm text-default") { "No unit types yet." }
        else
          ul(class: "mt-4 divide-y divide-default") { @levels.each { |level| level_row(level) } }
        end
        add_form if @can_edit_taxonomy
      end
    end
  end

  private

  def title = @structure ? words("own_unit_types", unit: @structure[:name]) : words("unit_types")

  def intro
    return "Unit types only the units beneath #{@structure[:name]} use, and the types each can sit under." if @structure

    "Each type of unit in the structure, and the types it can sit under. " \
      "A type an HRIS supplies sits at the top, or under one type above it that the HRIS supplies."
  end

  # An own structure's types are Espalia's, so they have no HRIS field.
  def connected? = @structure.nil? && @hris[:connected]

  def top_words = @structure ? words("can_sit_directly_under", unit: @structure[:name]) : words("can_sit_at_the_top")

  def top_place = @structure ? "directly under #{@structure[:name]}" : "at the top"

  def new_field_id = @structure ? "org-graph-new-level-#{@structure[:unit_id]}" : "org-graph-new-level"

  # Turbo drops a redirect's anchor, and an own structure's panel sits below
  # the fold, so its forms submit without Turbo to land back on it.
  def panel_form(url, **, &)
    @structure ? settings_form(url, **, data: { turbo: "false" }, &) : settings_form(url, **, &)
  end

  def structure_field
    return unless @structure

    input(type: "hidden", name: "structure_unit_id", value: @structure[:unit_id])
    input(type: "hidden", name: "back", value: "structure") if @on_structure_page
  end

  def level_row(level)
    li(id: "org-graph-level-#{level[:id]}", class: "py-3 first:pt-0 last:pb-0") do
      div(class: "flex flex-wrap items-center justify-between gap-x-4 gap-y-2") do
        div(class: "min-w-0") do
          p(class: "text-sm font-medium text-default") { level[:name] }
          p(class: "text-sm text-muted") { summary(level) }
        end
        div(id: "org-graph-level-actions-#{level[:id]}", class: "flex shrink-0 items-center gap-2") do
          hand_back_form(level) if @structure.nil? && level[:live_units].zero? && level[:provider] != ESPALIA
          level_menu(level) if @can_edit_taxonomy && level[:removable]
        end
      end
      if @can_edit_taxonomy
        rules_form(level)
      else
        p(class: "mt-1 text-sm text-default", id: "org-graph-level-rules-#{level[:id]}") { rules_sentence(level) }
      end
      next unless connected?

      if level[:live_units].zero?
        picker = self.class.picker(level[:id], level[:name])
        div(class: "mt-3") { render Views::Tenant::OrgGraph::Settings::FieldPickerFrame.new(picker:, src: picker.url) }
      else
        p(class: "mt-1 text-sm text-muted") { "It has units, so it changes hands through the handover below." }
      end
    end
  end

  def hand_back_form(level)
    panel_form(tenant_org_graph_settings_level_provider_path(level[:id]), method: :patch) do
      input(type: "hidden", name: "provider", value: ESPALIA)
      render Components::Kit::Button.new(
        variant: :outline, tone: :neutral, type: :submit, id: "org-graph-level-espalia-#{level[:id]}"
      ) { "Hold it in Espalia" }
    end
  end

  # The whole list replaces the type's rules, so every box posts, and the
  # hidden top value stands for an unticked switch. The was_ values are the
  # rules as drawn, so the controller can refuse a save over a newer change.
  def rules_form(level)
    panel_form(tenant_org_graph_settings_kind_parent_path(level[:id]), method: :patch,
                                                                          id: "org-graph-level-rules-#{level[:id]}",
                                                                          class: "mt-3") do
      structure_field
      level[:parent_ids].each { |id| input(type: "hidden", name: "was_parent_ids[]", value: id) }
      input(type: "hidden", name: "was_top", value: level[:top] ? "1" : "0")
      fieldset do
        legend(class: "text-sm font-medium text-default") { words("can_sit_under") }
        div(class: "mt-2 flex flex-wrap gap-x-5 gap-y-2") do
          @levels.each { |parent| parent_checkbox(level, parent) }
        end
      end
      div(class: "mt-3 flex flex-wrap items-center justify-between gap-3") do
        label(class: "flex items-center gap-2 text-sm text-default") do
          input(type: "hidden", name: "top", value: "0")
          input(type: "checkbox", name: "top", value: "1", checked: level[:top], id: "org-graph-level-top-#{level[:id]}",
                class: Components::Kit::Field::CHECKBOX)
          plain top_words
        end
        render Components::Kit::Button.new(variant: :outline, tone: :neutral, size: :sm, type: :submit,
                                           id: "org-graph-level-rules-save-#{level[:id]}") { "Save #{level[:name]}" }
      end
    end
  end

  def parent_checkbox(level, parent)
    id = "org-graph-level-#{level[:id]}-under-#{parent[:id]}"
    label(for: id, class: "flex items-center gap-2 text-sm text-default") do
      input(type: "checkbox", id:, name: "parent_ids[]", value: parent[:id], checked: level[:parent_ids].include?(parent[:id]),
            class: Components::Kit::Field::CHECKBOX)
      plain parent[:id] == level[:id] ? "#{parent[:name]} (inside another #{parent[:name]})" : parent[:name]
    end
  end

  # "Can sit under: Department, Team, or at the top", as #390 words it.
  def rules_sentence(level)
    names = @levels.select { level[:parent_ids].include?(it[:id]) }.map { it[:name] }
    return "#{top_words} only" if names.empty?

    "#{words('can_sit_under')}: #{names.join(', ')}#{", or #{top_place}" if level[:top]}"
  end

  # Remove is destructive, so it sits in the row's kebab, which opens the dialog.
  def level_menu(level)
    render Components::Kit::Modal.new(id: "org-graph-remove-level-#{level[:id]}", title: "Remove #{level[:name]}?",
                                      size: :sm) do |modal|
      render Components::Kit::Dropdown.new(align: :right, strategy: :fixed) do |menu|
        menu.trigger(label: "Actions for #{level[:name]}",
                     button: { variant: :ghost, size: :sm, icon: true, compact: true, id: "org-graph-level-menu-#{level[:id]}" }) do
          icon(:kebab, class: "size-4")
        end
        menu.menu(width: "w-44") do
          menu.item(tone: :danger, data: { action: "modal#open" }, id: "org-graph-level-remove-#{level[:id]}") do
            "Remove #{level[:name]}"
          end
        end
      end
      modal.body { remove_form(level) }
    end
  end

  def remove_form(level)
    p(class: "text-sm text-default") do
      "No unit is a #{level[:name]} from today on, so nothing else changes. Earlier dates still show it."
    end
    panel_form(tenant_org_graph_settings_level_path(level[:id]), method: :delete,
                                                                    class: "mt-4 flex justify-end gap-2") do
      structure_field
      render Components::Kit::Button.new(variant: :outline, tone: :neutral, data: { action: "modal#close" }) { "Cancel" }
      render Components::Kit::Button.new(tone: :danger, type: :submit, id: "org-graph-level-remove-confirm-#{level[:id]}") do
        "Remove #{level[:name]}"
      end
    end
  end

  def summary(level)
    held_now = level[:live_units].positive? ? "holds #{unit_names(level[:live_unit_names], level[:live_units])}" : "0 units"
    parts = [ source(level[:provider]), held_now ]
    parts << "held #{unit_names(level[:retired_unit_names], level[:retired_units])}" if level[:retired_units].positive?
    parts.join(" · ")
  end

  def unit_names(names, count)
    return names.to_sentence if count <= names.size

    "#{names.first(2).join(', ')} and #{count - 2} more"
  end

  def add_form
    panel_form(tenant_org_graph_settings_levels_path, class: "mt-4") do
      structure_field
      label(for: new_field_id, class: "block text-sm font-medium text-default") { "Name of the new unit type" }
      div(class: "mt-1 flex flex-col sm:flex-row gap-2") do
        input(id: new_field_id, name: "name", type: "text", required: true, autocomplete: "off",
              class: "#{Components::Kit::Field::INPUT} sm:flex-1 min-w-0")
        render Components::Kit::Button.new(variant: :outline, tone: :neutral, type: :submit, id: "#{new_field_id}-add") do
          "Add a unit type"
        end
      end
    end
  end

  # @return [String] one of #390's words, from config/locales/org_graph.en.yml
  def words(key, **) = I18n.t("org_graph.#{key}", **)

  def source(provider)
    return words("source.here") if provider == ESPALIA

    words("source.provider", provider: provider_label(provider))
  end

  def provider_label(provider)
    return "Espalia" if provider == ESPALIA

    provider == @hris[:provider] ? @hris[:label] : HrisConfig.provider_label(provider)
  end
end
