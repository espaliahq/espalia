# frozen_string_literal: true

# "Handing a level over": each level that holds units, compared with an HRIS
# field before it moves there, or handed back to Espalia. Each level loads in
# a frame of its own, since comparing reads the HRIS.
class Views::Tenant::OrgGraph::Settings::HandoverPanel < Views::Base
  # @param hris [Hash] provider, label and connected, as Operations::OrgGraph::Sources reads them
  # @param levels [Array<Hash>] id, name, provider, field and live_units, top first
  def initialize(hris:, levels:)
    @hris = hris
    @levels = levels
  end

  def view_template
    render Components::Kit::Card.new(title: "Handing a level over", heading_level: :h2, id: "org-graph-handover") do |card|
      card.body do
        p(class: "text-sm text-muted") do
          "A level that holds units moves to an HRIS field only once each unit has a call: the value it matches, " \
            "or the unit it is succeeded into, or its retirement. Nothing changes until you hand it over."
        end
        if handable.empty?
          p(class: "mt-4 text-sm text-default") { empty_message }
        else
          ul(class: "mt-4 divide-y divide-default") { handable.each { level_row(it) } }
        end
      end
    end
  end

  private

  def handable
    @handable ||= @levels.select do |level|
      level[:live_units].positive? && (@hris[:connected] || !espalia?(level))
    end
  end

  def espalia?(level) = [ nil, OrgGraph::StructureAggregate::ESPALIA ].include?(level[:provider])

  def empty_message
    return "No level holds units yet." if @levels.none? { it[:live_units].positive? }

    "Connect an HRIS to hand a level over to it."
  end

  def level_row(level)
    li(id: "org-graph-handover-#{level[:id]}", class: "py-3 first:pt-0 last:pb-0") do
      p(class: "text-sm font-medium text-default") { level[:name] }
      div(class: "mt-2") do
        render Views::Tenant::OrgGraph::Settings::HandoverFrame.new(
          level: level.slice(:id, :name), src: tenant_org_graph_settings_level_handover_path(level[:id])
        )
      end
    end
  end
end
