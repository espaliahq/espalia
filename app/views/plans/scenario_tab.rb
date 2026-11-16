# frozen_string_literal: true

# What the Changes and Checks tabs share: they each show one scenario of a plan,
# so a fix to the picker, a scenario's name or a source badge lands in both
# ([#354](https://github.com/espaliahq/espalia/issues/354)). The update-to-today
# preview names scenarios and facets with it too. A view that includes it
# defines `plan_id` and sets `@scenarios`; the picker also needs `scenario_id`.
module Views::Plans::ScenarioTab
  FACETS = {
    "assignment" => "Placement", "level" => "Level", "reporting_line" => "Manager", "departure" => "Leaving",
    "unit" => "Unit", "succession" => "Succession", "position" => "Position", "placeholder" => "Hire",
    "data:level" => "Level (plan value)", "data:fte" => "FTE (plan value)", "data:pay" => "Pay", "rule" => "Rule", "capacity" => "Capacity",
    "budget_line" => "Budget line", "funding" => "Funding", "cost_centre" => "Cost centre", "budget" => "Budget"
  }.freeze

  private

  # An archived plan's checks come back empty and unchecked, so the tab says
  # so rather than read as nothing wrong.
  #
  # @param report [Hash] the drift or attention read, with its `note`
  def unchecked(report)
    render Components::Kit::EmptyState.new(title: "Not checked while this plan is archived", size: :panel) do
      p(class: "text-sm text-muted") { report[:note] }
    end
  end

  # A pill per scenario on a wide screen; a phone picks from a list.
  #
  # @param path [Symbol] the tab's route helper, such as `:changes_plan_path`
  # @param select_id [String] the phone list's id, unique on the page
  def scenario_picker(path:, select_id:)
    div(class: "mt-3 flex flex-wrap items-center gap-2") do
      nav(aria: { label: "Scenario" }, class: "hidden sm:flex flex-wrap items-center gap-2 text-sm") do
        span(class: "text-muted") { "Showing" }
        @scenarios.each { scenario_pill(it, path) }
      end
      form(action: send(path, plan_id), method: "get", class: "flex min-w-0 flex-1 items-center gap-2 text-sm sm:hidden",
           data: { controller: "auto-submit" }) do
        label(for: select_id, class: "text-muted") { "Showing" }
        select(id: select_id, name: "scenario", class: "min-w-0 flex-1 #{Components::Kit::Field::SELECT}",
               data: { action: "change->auto-submit#submit" }) do
          Views::Plans::ScenarioTable.tree(@scenarios).each do |scenario, depth|
            option(value: scenario_param(scenario[:scenario_id]).to_s, selected: scenario[:scenario_id] == scenario_id) { "#{'· ' * depth}#{scenario_name(scenario[:scenario_id])}" }
          end
        end
        noscript { render Components::Kit::Button.new(variant: :outline, size: :sm, type: :submit) { "Show" } }
      end
    end
  end

  def scenario_pill(scenario, path)
    current = scenario[:scenario_id] == scenario_id
    a(href: send(path, plan_id, scenario: scenario_param(scenario[:scenario_id])), aria: { current: ("page" if current) },
      class: "rounded-full border px-3 py-1 #{current ? 'border-brand bg-brand-subtle font-medium text-default' : 'border-default text-muted hover:text-default'}") do
      scenario_name(scenario[:scenario_id])
    end
  end

  def sources(providers)
    providers.each { render Components::Kit::Badge.new("Source: #{HrisConfig.provider_label(it)}", variant: :outline) }
  end

  # A rule or a capacity names its own kind after the colon, as in "rule:on_cost".
  def facet_name(facet) = FACETS.fetch(facet) { FACETS.fetch(facet.split(":").first, facet.humanize) }

  def scenario_name(id)
    return "Today" if id == plan_id

    @scenarios.find { it[:scenario_id] == id }&.dig(:name) || "A removed scenario"
  end

  # The baseline is the tab's default, so its link names no scenario.
  def scenario_param(id) = (id unless id == plan_id)
end
