# frozen_string_literal: true

# "Levels": the structure's levels from the top down, and who supplies each.
# An empty level can be read from an HRIS field, or handed back to Espalia,
# here. A level that holds units changes hands through the handover.
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
  def initialize(hris:, levels:)
    @hris = hris
    @levels = levels
  end

  def view_template
    render Components::Kit::Card.new(title: "Levels", heading_level: :h2, id: "org-graph-levels") do |card|
      card.body do
        p(class: "text-sm text-muted") do
          "From the top of the organisation down. Levels an HRIS supplies sit above the ones Espalia holds."
        end
        if @levels.empty?
          p(class: "mt-4 text-sm text-default") { "No levels yet." }
        else
          ul(class: "mt-4 divide-y divide-default") { @levels.each { level_row(it) } }
        end
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
          p(class: "text-sm text-muted") { "From #{provider_label(level[:provider])} · #{units(level[:live_units])}" }
        end
        hand_back_form(level) if connected? && level[:live_units].zero? && level[:provider] != ESPALIA
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

  def units(count) = "#{count} #{count == 1 ? 'unit' : 'units'}"

  def provider_label(provider)
    return "Espalia" if provider == ESPALIA

    provider == @hris[:provider] ? @hris[:label] : HrisConfig.provider_label(provider)
  end
end
