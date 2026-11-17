# frozen_string_literal: true

# "Unit types": the structure's unit types, who supplies each, and where each
# can sit. An admin ticks the types each one can sit under, and whether it can
# sit at the top. An empty type can be read from an HRIS field, or handed back
# to Espalia, here; one that holds units changes hands through the handover.
# An admin adds a type, and removes one no unit has ever been.
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
  # @param can_edit_taxonomy [Boolean] whether the viewer may add, move and remove levels
  def initialize(hris:, levels:, can_edit_taxonomy: false)
    @hris = hris
    @levels = levels
    @can_edit_taxonomy = can_edit_taxonomy
  end

  def view_template
    render Components::Kit::Card.new(title: words("unit_types"), heading_level: :h2, id: "org-graph-levels") do |card|
      card.body do
        p(class: "text-sm text-muted") do
          plain "Each type of unit in the structure, and the types it can sit under. " \
                "A type an HRIS supplies takes its place from the HRIS."
        end
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

  def connected? = @hris[:connected]

  def level_row(level)
    li(id: "org-graph-level-#{level[:id]}", class: "py-3 first:pt-0 last:pb-0") do
      div(class: "flex flex-wrap items-center justify-between gap-x-4 gap-y-2") do
        div(class: "min-w-0") do
          p(class: "text-sm font-medium text-default") { level[:name] }
          p(class: "text-sm text-muted") { summary(level) }
        end
        div(id: "org-graph-level-actions-#{level[:id]}", class: "flex shrink-0 items-center gap-2") do
          hand_back_form(level) if level[:live_units].zero? && level[:provider] != ESPALIA
          level_menu(level) if @can_edit_taxonomy && level[:removable]
        end
      end
      if @can_edit_taxonomy && level[:provider] == ESPALIA
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
    settings_form(tenant_org_graph_settings_level_provider_path(level[:id]), method: :patch) do
      input(type: "hidden", name: "provider", value: ESPALIA)
      render Components::Kit::Button.new(
        variant: :outline, tone: :neutral, type: :submit, id: "org-graph-level-espalia-#{level[:id]}"
      ) { "Hold it in Espalia" }
    end
  end

  # The whole list replaces the type's rules, so every box posts, and the
  # hidden top value stands for an unticked switch.
  def rules_form(level)
    settings_form(tenant_org_graph_settings_kind_parent_path(level[:id]), method: :patch,
                                                                          id: "org-graph-level-rules-#{level[:id]}",
                                                                          class: "mt-3") do
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
          plain words("can_sit_at_the_top")
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
    return "#{words('can_sit_at_the_top')} only" if names.empty?

    "#{words('can_sit_under')}: #{names.join(', ')}#{', or at the top' if level[:top]}"
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
    p(class: "text-sm text-default") { "No unit has ever been a #{level[:name]}, so nothing else changes." }
    settings_form(tenant_org_graph_settings_level_path(level[:id]), method: :delete,
                                                                    class: "mt-4 flex justify-end gap-2") do
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
    settings_form(tenant_org_graph_settings_levels_path, class: "mt-4") do
      label(for: "org-graph-new-level", class: "block text-sm font-medium text-default") { "Name of the new unit type" }
      div(class: "mt-1 flex flex-col sm:flex-row gap-2") do
        input(id: "org-graph-new-level", name: "name", type: "text", required: true, autocomplete: "off",
              class: "#{Components::Kit::Field::INPUT} sm:flex-1 min-w-0")
        render Components::Kit::Button.new(variant: :outline, tone: :neutral, type: :submit) { "Add a unit type" }
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
