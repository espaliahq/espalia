# frozen_string_literal: true

# "Levels": the structure's levels from the top down, and who supplies each.
# An empty level can be read from an HRIS field, or handed back to Espalia,
# here. A level that holds units changes hands through the handover. An admin
# adds a level at the bottom and moves the ones Espalia holds a place at a time.
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
  # @param levels [Array<Hash>] id, name, provider, field and live_units, top first
  # @param can_edit_taxonomy [Boolean] whether the viewer may add and move levels
  def initialize(hris:, levels:, can_edit_taxonomy: false)
    @hris = hris
    @levels = levels
    @can_edit_taxonomy = can_edit_taxonomy
  end

  def view_template
    render Components::Kit::Card.new(title: "Levels", heading_level: :h2, id: "org-graph-levels") do |card|
      card.body do
        p(class: "text-sm text-muted") do
          "From the top of the organisation down. Levels an HRIS supplies sit above the ones Espalia holds. " \
            "A new level starts at the bottom; move it into place."
        end
        if @levels.empty?
          p(class: "mt-4 text-sm text-default") { "No levels yet." }
        else
          ul(class: "mt-4 divide-y divide-default") { @levels.each_with_index { |level, index| level_row(level, index) } }
        end
        add_form if @can_edit_taxonomy
      end
    end
  end

  private

  def connected? = @hris[:connected]

  def level_row(level, index)
    li(id: "org-graph-level-#{level[:id]}", class: "py-3 first:pt-0 last:pb-0") do
      div(class: "flex flex-wrap items-center justify-between gap-x-4 gap-y-2") do
        div(class: "min-w-0") do
          p(class: "text-sm font-medium text-default") { level[:name] }
          p(class: "text-sm text-muted") { "From #{provider_label(level[:provider])} · #{units(level[:live_units])}" }
        end
        div(id: "org-graph-level-actions-#{level[:id]}", class: "flex shrink-0 items-center gap-2") do
          hand_back_form(level) if level[:live_units].zero? && level[:provider] != ESPALIA
          move_buttons(level, index) if @can_edit_taxonomy && level[:provider] == ESPALIA
        end
      end
      next unless connected?

      if level[:live_units].zero?
        picker = self.class.picker(level[:id], level[:name])
        div(class: "mt-3") { render Views::Tenant::OrgGraph::Settings::FieldPickerFrame.new(picker:, src: picker.url) }
      else
        p(class: "mt-1 text-sm text-muted") { "It holds units, so it changes hands through the handover below." }
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

  def move_buttons(level, index)
    div(class: "flex items-center gap-1") do
      move_button(level, index, index - 1, "up")
      move_button(level, index, index + 1, "down")
    end
  end

  # Swapping two levels that both hold units would put a unit above its
  # parent's level, and a level an HRIS supplies keeps its place, so those
  # moves get no button.
  def move_button(level, from, to, direction)
    other = @levels[to] if to >= 0
    if other.nil? || other[:provider] != ESPALIA || (level[:live_units].positive? && other[:live_units].positive?)
      span(class: "size-8 shrink-0", aria: { hidden: "true" })
      return
    end

    order = @levels.map { it[:id] }
    order[from], order[to] = order[to], order[from]
    settings_form(tenant_org_graph_settings_level_order_path, method: :patch, class: "contents") do
      order.each { input(type: "hidden", name: "level_ids[]", value: it) }
      input(type: "hidden", name: "level_id", value: level[:id])
      input(type: "hidden", name: "direction", value: direction)
      render Components::Kit::Button.new(
        variant: :ghost, tone: :neutral, size: :sm, icon: true, compact: true, type: :submit,
        id: "org-graph-level-#{direction}-#{level[:id]}", aria_label: "Move #{level[:name]} #{direction}"
      ) { icon(:"chevron-#{direction}", class: "size-4") }
    end
  end

  def add_form
    settings_form(tenant_org_graph_settings_levels_path, class: "mt-4 flex flex-col sm:flex-row gap-2") do
      label(for: "org-graph-new-level", class: "sr-only") { "Name of the new level" }
      input(id: "org-graph-new-level", name: "name", type: "text", required: true, autocomplete: "off",
            class: "#{Components::Kit::Field::INPUT} sm:flex-1 min-w-0")
      render Components::Kit::Button.new(variant: :outline, tone: :neutral, type: :submit) { "Add a level" }
    end
  end

  def units(count) = "#{count} #{count == 1 ? 'unit' : 'units'}"

  def provider_label(provider)
    return "Espalia" if provider == ESPALIA

    provider == @hris[:provider] ? @hris[:label] : HrisConfig.provider_label(provider)
  end
end
