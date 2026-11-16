# frozen_string_literal: true

# A plan's scenarios as a tree (#226): the baseline first, read-only, and each
# scenario under the one it follows or replaces.
#
# Later stories add columns (cost and capacity) through `extra_columns:`,
# each a heading and a callable that returns the component for a scenario's
# cell. Below `sm` each column stacks under the name, after its heading.
class Views::Plans::ScenarioTable < Views::Base
  # A column a later story adds: a heading, and how to draw its cell.
  Column = Data.define(:heading, :cell)

  # Columns beside the name show from `sm` up; below it they stack under the name.
  WIDE = "hidden sm:table-cell"

  # Depth-first from the baseline, so each scenario sits under its parent.
  #
  # @param scenarios [Array<Hash>] from `team_planning_scenarios`
  # @return [Array<Array(Hash, Integer)>] each scenario with its depth
  def self.tree(scenarios)
    children = scenarios.group_by { it[:parent_id] }
    walk = ->(scenario, depth) { [ [ scenario, depth ], *(children[scenario[:scenario_id]] || []).flat_map { walk.(it, depth + 1) } ] }
    (children[nil] || []).flat_map { walk.(it, 0) }
  end

  # @param plan_id [String]
  # @param scenarios [Array<Hash>] from `team_planning_scenarios`, baseline first
  # @param extra_columns [Array<Column>]
  # @param can_edit [Boolean] whether each row offers a menu to fork and edit
  def initialize(plan_id:, scenarios:, extra_columns: [], can_edit: false)
    @plan_id = plan_id
    @scenarios = scenarios
    @extra_columns = extra_columns
    @can_edit = can_edit
  end

  def view_template
    render Components::Kit::Card.new(variant: :flush) do |card|
      card.body do
        div(class: "overflow-x-auto") do
          table(class: "w-full text-sm") do
            thead do
              tr(class: "border-b border-default text-left text-muted") do
                th(scope: "col", class: "px-4 py-2 font-medium") { "Scenario" }
                th(scope: "col", class: "#{WIDE} px-4 py-2 font-medium") { "Period" }
                @extra_columns.each { |column| th(scope: "col", class: "#{WIDE} px-4 py-2 font-medium") { column.heading } }
                th(scope: "col", class: "#{WIDE} px-4 py-2 font-medium") { "State" }
                th(scope: "col", class: "w-0 px-2 py-2") { span(class: "sr-only") { "Actions" } } if @can_edit
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
            a(href: map_plan_path(@plan_id, scenario: (scenario[:scenario_id] unless baseline)), class: "text-link underline") do
              baseline ? "Today" : scenario[:name]
            end
          end
          p(class: "text-muted") { "The Org Graph. Nothing set by this plan." } if baseline
          render Components::Kit::Prose.new(scenario[:description], class: "mt-0.5 text-muted") if scenario[:description]
          div(class: "sm:hidden mt-1 flex flex-wrap items-center gap-2 text-muted") do
            period_cell(scenario)
            state(baseline)
          end
          @extra_columns.each do |column|
            div(class: "sm:hidden mt-1 flex flex-wrap items-baseline gap-x-2") do
              span(class: "text-muted") { "#{column.heading}:" }
              render column.cell.call(scenario)
            end
          end
        end
      end
      td(class: "#{WIDE} px-4 py-3 align-top text-muted whitespace-nowrap") { period_cell(scenario) }
      @extra_columns.each { |column| td(class: "#{WIDE} px-4 py-3 align-top") { render column.cell.call(scenario) } }
      td(class: "#{WIDE} px-4 py-3 align-top") { state(baseline) }
      td(class: "px-2 py-2 align-top text-right") { row_menu(scenario, baseline) } if @can_edit
    end
  end

  def row_menu(scenario, baseline)
    name = baseline ? "Today" : scenario[:name]
    render Components::Kit::Dropdown.new(strategy: :fixed) do |menu|
      menu.trigger(label: "Actions for #{name}", button: { variant: :ghost, size: :xs, icon: true, compact: true }) do
        icon("kebab", class: "size-4")
      end
      menu.menu(width: "w-56") do
        menu.item(data: Views::Plans::ScenarioDialogs.fork_trigger(scenario[:scenario_id])) { "New scenario from here…" }
        unless baseline
          menu.item(data: Views::Plans::ScenarioDialogs.edit_trigger(plan_scenario_path(@plan_id, scenario[:scenario_id]), scenario)) do
            "Edit…"
          end
          if (step = self.class.dated_step(scenario, @scenarios))
            menu.item(href: dates_plan_path(@plan_id, scenario_id: step[:scenario_id])) { "Dates…" }
          end
          menu.item(href: split_plan_path(@plan_id, scenario_id: scenario[:scenario_id])) { "Split off the agreed part…" }
        end
      end
    end
  end

  def state(baseline)
    render Components::Kit::Badge.new(baseline ? "Read only" : "Draft", tone: baseline ? :neutral : :info)
  end

  def period(scenario) = self.class.period(scenario)

  def period_cell(scenario)
    span { period(scenario) }
    continues = self.class.today_continues_to(@scenarios) if scenario[:parent_id].nil?
    span(class: "block", data: { today_continues: continues.iso8601 }) { "Today continues to #{continues.strftime('%-d %b %Y')}" } if continues
  end

  # The last day Today runs on its own, when the plan's first step starts
  # after the base date ([#404](https://github.com/espaliahq/espalia/issues/404)).
  #
  # @param scenarios [Array<Hash>] from `team_planning_scenarios`
  # @return [Date, nil]
  def self.today_continues_to(scenarios)
    baseline = scenarios.find { it[:parent_id].nil? }
    first = scenarios.find { dated?(it) && it[:parent_id] == baseline&.dig(:scenario_id) }
    return unless first && first[:starts_on] > baseline[:starts_on]

    Date.iso8601(first[:starts_on]) - 1
  end

  # Whether a step comes after this scenario's period, through it or anything
  # that shares the period, so it can't be left without an end.
  #
  # @param scenario [Hash] from `team_planning_scenarios`
  # @param scenarios [Array<Hash>] the plan's scenarios
  # @return [Boolean]
  def self.continues?(scenario, scenarios)
    scenarios.any? { it[:parent_id] == scenario[:scenario_id] && (it[:relation] == "then" || continues?(it, scenarios)) }
  end

  # Whether a scenario has dates of its own to change: a step that follows
  # another. A split's halves and an alternative take their parent's period.
  #
  # @param scenario [Hash] from `team_planning_scenarios`
  # @return [Boolean]
  def self.dated?(scenario)
    case scenario[:relation]
    in "then" then true
    in "on" | "instead" | nil then false
    end
  end

  # The step whose dates a scenario's Dates… page changes, as the aggregate
  # resolves it: a step itself, the rest of a split its step, and an
  # alternative none, as it can't be moved apart from what it replaces.
  #
  # @param scenario [Hash] from `team_planning_scenarios`
  # @param scenarios [Array<Hash>] the plan's scenarios
  # @return [Hash, nil]
  def self.dated_step(scenario, scenarios)
    case scenario[:relation]
    in "then" then scenario
    in "on" then period_owner(scenario, scenarios)
    in "instead" | nil then nil
    end
  end

  # The step whose dates a scenario takes: itself for a step, else the
  # nearest step above it. Nil for the baseline.
  #
  # @param scenario [Hash, nil] from `team_planning_scenarios`
  # @param scenarios [Array<Hash>] the plan's scenarios
  # @return [Hash, nil]
  def self.period_owner(scenario, scenarios)
    case scenario&.dig(:relation)
    in "then" then scenario
    in "on" | "instead" then period_owner(scenarios.find { it[:scenario_id] == scenario[:parent_id] }, scenarios)
    in nil then nil
    end
  end

  # A scenario's period as the plan's pages print it: "As of" for the baseline,
  # whole months by name.
  #
  # @param scenario [Hash] from `team_planning_scenarios`
  # @return [String]
  def self.period(scenario)
    starts = Date.iso8601(scenario[:starts_on])
    return "As of #{starts.strftime('%-d %b %Y')}" if scenario[:parent_id].nil?
    return "From #{starts.strftime('%-d %b %Y')} · no end date" unless scenario[:ends_on]

    ends = Date.iso8601(scenario[:ends_on])
    whole_months = starts.day == 1 && ends == ends.end_of_month
    unit = whole_months ? "%b" : "%-d %b"
    return starts.strftime("%b %Y") if whole_months && starts.month == ends.month && starts.year == ends.year

    first = starts.year == ends.year ? starts.strftime(unit) : starts.strftime("#{unit} %Y")
    "#{first} to #{ends.strftime("#{unit} %Y")}"
  end

  # The days a cost or budget read figures, as its basis line prints them. A
  # step with no end date is figured over its horizon, and says so.
  #
  # @param period [Hash] a figures read's `period`
  # @return [String] such as "1 Apr 2027 to 31 Mar 2028, the first 12 months of a step with no end date"
  def self.figured(period)
    days = "#{day(period[:starts_on])} to #{day(period[:ends_on])}"
    period[:open_ended] ? "#{days}, the first #{period[:horizon_months]} months of a step with no end date" : days
  end

  def self.day(iso) = Date.iso8601(iso).strftime("%-d %b %Y")

  def ordered = self.class.tree(@scenarios)
end
