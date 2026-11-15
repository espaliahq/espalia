# frozen_string_literal: true

# A plan's Checks tab ([#350](https://github.com/espaliahq/espalia/issues/350)):
# what no longer fits in one scenario, grouped by the check that found it, in
# `team_planning_attention`'s order. Each item names its subject, the reason,
# the change behind it and where to fix it. It reads Attention and decides
# none of its rules.
class Views::Plans::ChecksTab < Views::Base
  # A check this tab has no heading for still shows, under its key.
  HEADINGS = {
    placements: [ "Placements", "People placed in a unit or position the scenario no longer has." ],
    positions: [ "Positions", "Positions in a unit the scenario retired, or filled past their FTE." ],
    units: [ "Units", "Units whose parent the scenario retired." ],
    unresolved: [ "People the plan can't place", "People placed who joined after the base or have left, so the Org Graph can't place them." ],
    successions: [ "Successions", "Successions whose units no longer read the way the succession says." ],
    capacity_overrides: [ "Capacity overrides", "Overrides on a place the person no longer holds." ],
    allocations: [ "Allocations", "People placed nowhere, or over or under 100% allocated." ],
    leavers: [ "Leavers", "People still in the plan after the Org Graph has them leave." ],
    managers: [ "Managers", "People with no manager, or one who is gone, has left or shares none of their units." ],
    overloaded: [ "Overloaded managers", "Seats whose reports cost more to manage than the seat delivers." ],
    unclassified: [ "Capacity", "Places no capacity model covers." ],
    budget_lines: [ "Budget lines", "Changes to budget lines the organisation has since removed." ]
  }.freeze
  FACETS = {
    "assignment" => "Placement", "level" => "Level", "reporting_line" => "Manager", "departure" => "Leaving",
    "unit" => "Unit", "succession" => "Succession", "position" => "Position", "capacity" => "Capacity",
    "budget_line" => "Budget line"
  }.freeze

  # @param check [String, Symbol]
  # @return [String] the group's heading, or the key itself for a check with none
  def self.heading(check) = HEADINGS.dig(check.to_sym, 0) || check.to_s

  # @param plan [Hash] from `team_planning_plan`
  # @param scenarios [Array<Hash>] from `team_planning_scenarios`, baseline first
  # @param attention [Hash] from `team_planning_attention`
  # @param linked_ids [Set<String>] the changes the Changes tab lists for the same scenario, so a link lands on a row
  def initialize(plan:, scenarios:, attention:, linked_ids: Set.new)
    @plan = plan
    @scenarios = scenarios
    @attention = attention
    @linked_ids = linked_ids
  end

  def view_template
    section(aria: { labelledby: "checks-heading" }, class: "space-y-6", data: { checks_tab: scenario_id }) do
      div do
        h3(id: "checks-heading", class: "text-base font-semibold text-default") { "Checks on #{scenario_name(scenario_id)}" }
        p(class: "mt-1 text-sm text-muted") { "What no longer fits in this scenario, often because a scenario it follows changed later." }
        scenario_picker
      end
      if @attention[:items].empty?
        render Components::Kit::EmptyState.new(title: "Everything in this scenario still fits.", size: :panel)
      else
        summary
        groups.each { |check, items| group(check, items) }
      end
    end
  end

  private

  def plan_id = @plan[:plan_id]

  def scenario_id = @attention[:scenario_id]

  # Every check Attention runs, found something or not, then any it gained that the tab has no heading for.
  def groups
    @groups ||= begin
      found = @attention[:items].group_by { it[:check].to_s }
      TeamPlanning::Attention::CHECKS.to_h { [ it.to_s, found.delete(it.to_s) || [] ] }.merge(found)
    end
  end

  def summary
    nav(aria: { label: "Checks" }, class: "flex flex-wrap gap-2 text-sm") do
      groups.each do |check, items|
        next if items.empty?

        a(href: "##{group_id(check)}", class: "rounded-full border border-default px-3 py-1 text-muted hover:text-default") do
          plain "#{self.class.heading(check)} "
          span(class: "font-medium text-default") { items.size.to_s }
        end
      end
    end
  end

  def group(check, items)
    section(id: group_id(check), aria: { labelledby: "#{group_id(check)}-heading" }, data: { check: }) do
      h4(id: "#{group_id(check)}-heading", class: "text-sm font-semibold text-default") { self.class.heading(check) }
      if (sentence = HEADINGS.dig(check.to_sym, 1))
        p(class: "mt-1 text-sm text-muted") { sentence }
      end
      if items.empty?
        div(class: "mt-3") { render Components::Kit::EmptyState.new(title: "Nothing to fix here.", size: :panel) }
      else
        ul(class: "mt-3 divide-y divide-default rounded-lg border border-default bg-default") { items.each { item_row(it) } }
      end
    end
  end

  def item_row(item)
    li(class: "flex flex-col gap-2 p-3 sm:flex-row sm:items-start sm:justify-between", data: { check_item: item[:facet] }) do
      div(class: "min-w-0 space-y-1") do
        p(class: "text-sm text-default break-words") do
          facet = FACETS.fetch(item[:facet].split(":").first) { item[:facet].humanize }
          if (name = @attention[:names][item[:subject_id]])
            strong(class: "font-medium") { name }
            plain " · #{facet}"
          else
            strong(class: "font-medium") { facet }
          end
        end
        p(class: "text-sm text-muted") { item[:reason] }
        p(class: "text-xs text-muted") { cause(item[:change]) }
      end
      div(class: "flex flex-wrap items-center gap-1.5 sm:justify-end") { sources(item[:sources]) }
    end
  end

  # A change the Changes tab has no row for, such as a rule, is named without a link.
  def cause(change)
    return plain("Nothing in the plan explains it.") unless change

    where = "a change in #{scenario_name(change[:scenario_id])}"
    plain "From "
    if @linked_ids.include?(change[:event_id])
      a(href: changes_plan_path(plan_id, scenario: scenario_param(scenario_id), anchor: Views::Plans::ChangesTab.change_anchor(change[:event_id])),
        class: "text-link underline") { where }
    else
      plain where
    end
  end

  def group_id(check) = "checks-#{check.to_s.dasherize}"

  # A pill per scenario on a wide screen; a phone picks from a list.
  def scenario_picker
    div(class: "mt-3 flex flex-wrap items-center gap-2") do
      nav(aria: { label: "Scenario" }, class: "hidden sm:flex flex-wrap items-center gap-2 text-sm") do
        span(class: "text-muted") { "Showing" }
        @scenarios.each { scenario_pill(it) }
      end
      form(action: checks_plan_path(plan_id), method: "get", class: "flex min-w-0 flex-1 items-center gap-2 text-sm sm:hidden",
           data: { controller: "auto-submit" }) do
        label(for: "checks-scenario", class: "text-muted") { "Showing" }
        select(id: "checks-scenario", name: "scenario", class: "min-w-0 flex-1 #{Components::Kit::Field::SELECT}",
               data: { action: "change->auto-submit#submit" }) do
          Views::Plans::ScenarioTable.tree(@scenarios).each do |scenario, depth|
            option(value: scenario_param(scenario[:scenario_id]).to_s, selected: scenario[:scenario_id] == scenario_id) { "#{'· ' * depth}#{scenario_name(scenario[:scenario_id])}" }
          end
        end
        noscript { render Components::Kit::Button.new(variant: :outline, size: :sm, type: :submit) { "Show" } }
      end
    end
  end

  def scenario_pill(scenario)
    current = scenario[:scenario_id] == scenario_id
    a(href: checks_plan_path(plan_id, scenario: scenario_param(scenario[:scenario_id])), aria: { current: ("page" if current) },
      class: "rounded-full border px-3 py-1 #{current ? 'border-brand bg-brand-subtle font-medium text-default' : 'border-default text-muted hover:text-default'}") do
      scenario_name(scenario[:scenario_id])
    end
  end

  def sources(providers)
    providers.each { render Components::Kit::Badge.new("Source: #{HrisConfig.provider_label(it)}", variant: :outline) }
  end

  def scenario_name(id)
    return "Today" if id == plan_id

    @scenarios.find { it[:scenario_id] == id }&.dig(:name) || "A removed scenario"
  end

  def scenario_param(id) = (id unless id == plan_id)
end
