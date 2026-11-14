# frozen_string_literal: true

# The Units view's left column: every live unit in tree order, each with its
# head count, and a link down to the In no team tray.
class Views::Tenant::OrgGraph::UnitTree < Views::Base
  include Phlex::Rails::Helpers::Routes
  include Views::Tenant::OrgGraph::Formatting

  # @param overview [OrgGraph::UnitsOverview]
  # @param tray_id [String] the tray's element id, for the In no team link
  # @param comparison [OrgGraph::Comparison] marks a unit that changed in the window
  def initialize(overview:, tray_id:, comparison: OrgGraph::Comparison::NONE)
    @overview = overview
    @tray_id = tray_id
    @comparison = comparison
  end

  def view_template
    nav(
      class: "lg:w-64 lg:shrink-0 lg:self-start bg-default border border-default rounded-2xl p-3",
      aria: { labelledby: "org-graph-tree-label" }
    ) do
      p(id: "org-graph-tree-label", class: "px-2 pb-2 text-xs font-semibold uppercase tracking-wide text-muted") do
        @overview.levels.map(&:name).join(", ")
      end
      tree_list(@overview.roots)
      a(
        href: "##{@tray_id}",
        class: [
          "mt-2 flex items-center justify-between rounded-md px-2 py-1.5 text-sm font-medium hover:bg-default-hover",
          @overview.unplaced.any? ? "text-warning" : "text-default"
        ]
      ) do
        span { "In no team" }
        span(class: "tabular-nums") { @overview.unplaced.size.to_s }
      end
    end
  end

  private

  def tree_list(units)
    ul(class: "space-y-0.5") do
      units.each do |unit|
        li do
          tree_link(unit)
          children = @overview.children_of(unit)
          div(class: "pl-4") { tree_list(children) } if children.any?
        end
      end
    end
  end

  def tree_link(unit)
    selected = unit.id == @overview.selected&.id
    a(
      href: tenant_org_graph_path(unit: unit.id, **@comparison.params),
      class: [
        "block rounded-md px-2 py-1.5 text-sm",
        selected ? "bg-neutral-muted font-semibold text-default" : "text-default hover:bg-default-hover"
      ],
      aria: { current: selected ? "page" : nil }
    ) do
      span(class: "flex items-center gap-1.5") do
        span(class: "min-w-0 truncate") { unit.name }
        hris_lock(unit) unless unit.held_by_espalia?
        span(class: "ml-auto pl-2 tabular-nums text-muted") { @overview.headcount(unit).to_s }
      end
      unit_marks(unit)
    end
  end

  def unit_marks(unit)
    marks = @comparison.unit_marks(unit)
    return if marks.empty?

    span(class: "mt-1 flex flex-wrap gap-1") { marks.each { render Components::Kit::Badge.new(it, tone: :info) } }
  end

  def hris_lock(unit)
    icon(:lock, class: "size-3.5 shrink-0 text-muted")
    span(class: "sr-only") { "from #{provider_label(unit)}" }
  end
end
