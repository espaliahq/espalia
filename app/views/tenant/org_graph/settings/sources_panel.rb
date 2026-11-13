# frozen_string_literal: true

# "Where each fact comes from": Espalia, where people edit a fact, or the
# connected HRIS, whose sync supplies it. A fact read from a field of the
# tenant's choosing also shows that field's picker.
class Views::Tenant::OrgGraph::Settings::SourcesPanel < Views::Base
  include Views::Tenant::OrgGraph::Settings::FormHelpers
  include Views::Tenant::OrgGraph::Settings::FactLabels

  ESPALIA = OrgGraph::StructureAggregate::ESPALIA

  # @param hris [Hash] provider, label and connected, as Operations::OrgGraph::Sources reads them
  # @param facts [Array<Hash>] fact, provider, fields and mappable_parts, as Operations::OrgGraph::Sources reads them
  def initialize(hris:, facts:)
    @hris = hris
    @facts = facts
  end

  def view_template
    render Components::Kit::Card.new(title: "Where each fact comes from", heading_level: :h2, id: "org-graph-sources") do |card|
      card.body do
        p(class: "text-sm text-muted") { intro }
        ul(class: "mt-4 divide-y divide-default") do
          @facts.each { fact_row(it) }
        end
      end
    end
  end

  private

  def connected? = @hris[:connected]

  def intro
    if connected?
      "Espalia's facts are edited here; #{@hris[:label]}'s are read by each sync, which overwrites them. " \
        "A change takes effect today."
    else
      "No HRIS is connected, so every fact is edited in Espalia."
    end
  end

  def fact_row(fact)
    li(id: "org-graph-fact-#{fact[:fact]}", class: "py-3 first:pt-0 last:pb-0") do
      div(class: "flex flex-wrap items-center justify-between gap-x-4 gap-y-2") do
        div(class: "min-w-0") do
          p(class: "text-sm font-medium text-default") { fact_label(fact[:fact]) }
          p(class: "text-sm text-muted") { "From #{provider_label(fact[:provider])}" }
        end
        provider_form(fact) if connected?
      end
      field_picker(fact) if connected? && fact[:provider] != ESPALIA && fact[:mappable_parts].any?
    end
  end

  def provider_form(fact)
    name = fact[:fact]
    select_id = "org-graph-fact-provider-#{name}"
    settings_form(tenant_org_graph_settings_fact_provider_path(name), method: :patch, class: "flex items-center gap-2") do
      label(for: select_id, class: "sr-only") { "Source of #{fact_label(name).downcase}" }
      select(id: select_id, name: "provider", class: Components::Kit::Field::SELECT) do
        [ ESPALIA, @hris[:provider] ].each do |provider|
          option(value: provider, selected: provider == fact[:provider]) { provider_label(provider) }
        end
      end
      render Components::Kit::Button.new(
        variant: :outline, tone: :neutral, type: :submit, id: "org-graph-fact-save-#{name}",
        aria_label: "Save the source of #{fact_label(name).downcase}"
      ) { "Save" }
    end
  end

  def field_picker(fact)
    div(class: "mt-3") do
      render Views::Tenant::OrgGraph::Settings::FactFieldFrame.new(
        fact: fact[:fact], part: fact[:mappable_parts].first,
        src: tenant_org_graph_settings_fact_field_path(fact[:fact])
      )
    end
  end

  def provider_label(provider)
    return "Espalia" if provider == ESPALIA

    provider == @hris[:provider] ? @hris[:label] : HrisConfig.provider_label(provider)
  end
end
