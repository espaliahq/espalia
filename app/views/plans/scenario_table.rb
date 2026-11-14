# frozen_string_literal: true

# A plan's scenarios as a tree (#226): the baseline first, read-only, and each
# scenario under the one it follows or replaces.
#
# Later stories add columns (cost and capacity) through `extra_columns:`,
# each a heading and a block that draws its cell for a scenario.
class Views::Plans::ScenarioTable < Views::Base
  # A column a later story adds: a heading, and how to draw its cell.
  Column = Data.define(:heading, :cell)

  # @param scenarios [Array<Hash>] from `team_planning_scenarios`, baseline first
  # @param base_on [Date] the plan's base date
  # @param extra_columns [Array<Column>]
  def initialize(scenarios:, base_on:, extra_columns: [])
    @scenarios = scenarios
    @base_on = base_on
    @extra_columns = extra_columns
  end

  def view_template
    render Components::Kit::Card.new(variant: :flush) do |card|
      card.body do
        div(class: "overflow-x-auto") do
          table(class: "w-full text-sm") do
            thead do
              tr(class: "border-b border-default text-left text-muted") do
                th(scope: "col", class: "px-4 py-2 font-medium") { "Scenario" }
                th(scope: "col", class: "px-4 py-2 font-medium") { "When" }
                @extra_columns.each { |column| th(scope: "col", class: "px-4 py-2 font-medium") { column.heading } }
                th(scope: "col", class: "px-4 py-2 font-medium") { "State" }
              end
            end
            tbody(class: "divide-y divide-subtle") { ordered.each { |scenario, depth| row(scenario, depth) } }
          end
        end
      end
    end
  end

  private

  def row(scenario, depth)
    baseline = scenario[:parent_id].nil?
    tr(data: { scenario_id: scenario[:scenario_id] }) do
      td(class: "px-4 py-3 align-top") do
        div(style: ("padding-left: #{depth * 1.25}rem" if depth.positive?)) do
          p(class: "font-medium text-default") do
            span(class: "text-muted font-normal") { "#{scenario[:relation]} " } if scenario[:relation]
            plain(baseline ? "Baseline" : scenario[:name])
          end
          p(class: "text-muted") { "The Org Graph on #{@base_on.strftime("%-d %B %Y")}. Nothing set by this plan." } if baseline
        end
      end
      td(class: "px-4 py-3 align-top text-muted whitespace-nowrap") { period(scenario) }
      @extra_columns.each { |column| td(class: "px-4 py-3 align-top") { column.cell.call(scenario) } }
      td(class: "px-4 py-3 align-top") do
        render Components::Kit::Badge.new(baseline ? "Read only" : "Draft", tone: baseline ? :neutral : :info)
      end
    end
  end

  def period(scenario)
    starts = Date.iso8601(scenario[:starts_on])
    return "From #{starts.strftime("%-d %B %Y")}" unless scenario[:ends_on]

    ends = Date.iso8601(scenario[:ends_on])
    first = starts.year == ends.year ? starts.strftime("%b") : starts.strftime("%b %Y")
    "#{first} to #{ends.strftime('%b %Y')}"
  end

  # Depth-first from the baseline, so each scenario sits under its parent.
  def ordered
    children = @scenarios.group_by { it[:parent_id] }
    walk = ->(scenario, depth) { [ [ scenario, depth ], *(children[scenario[:scenario_id]] || []).flat_map { walk.(it, depth + 1) } ] }
    (children[nil] || []).flat_map { walk.(it, 0) }
  end
end
