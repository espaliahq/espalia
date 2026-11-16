# frozen_string_literal: true

# A step's dates ([#404](https://github.com/espaliahq/espalia/issues/404)):
# the editor picks new ones, previews what they move, then saves. A later step
# starts the day after the one before it ends, so only a first step's start is
# its own to change. What moves comes from `team_planning_period_preview`, and
# the page never works it out itself.
class Views::Plans::ScenarioDates < Views::Base
  include Views::Plans::ScenarioTab

  # @param plan [Hash] from `team_planning_plan`
  # @param scenarios [Array<Hash>] from `team_planning_scenarios`
  # @param scenario [Hash] the step whose dates change
  # @param draft [Hash] `{ starts_on:, ends_on: }` the editor asked for
  # @param preview [Hash, nil] from `team_planning_period_preview`, for the draft
  # @param error [String, nil] why the draft was refused
  # @param from [String, nil] "map" when the editor came from the map
  # @param map_scenario [String, nil] the map's scenario when it isn't this step, as for an alternative
  def initialize(plan:, scenarios:, scenario:, draft: {}, preview: nil, error: nil, from: nil, map_scenario: nil)
    @plan = plan
    @scenarios = scenarios
    @scenario = scenario
    @draft = draft
    @preview = preview
    @error = error
    @from = from
    @map_scenario = map_scenario if from == "map"
  end

  def view_template
    section(aria: { labelledby: "dates-heading" }, class: "space-y-6", data: { scenario_dates: id }) do
      div do
        h3(id: "dates-heading", class: "text-base font-semibold text-default break-words") { "Dates for #{@scenario[:name]}" }
        p(class: "mt-1 text-sm text-muted", data: { dates_current: id }) { "Now #{period(@scenario)}." }
      end
      render(Components::Kit::Alert.new(tone: :danger, role: "alert", title: "Couldn't use those dates")) { @error } if @error
      choose
      confirm if changes?
    end
  end

  private

  def plan_id = @plan[:plan_id]

  def id = @scenario[:scenario_id]

  def first_step? = @scenario[:parent_id] == plan_id

  # The step whose end this one starts after: its parent, or the step that
  # parent takes its period from when the parent is a split or an alternative.
  def parent = Views::Plans::ScenarioTable.period_owner(@scenarios.find { it[:scenario_id] == @scenario[:parent_id] }, @scenarios)

  def back = map_to_return_to ? map_plan_path(plan_id, scenario: map_to_return_to) : plan_path(plan_id)

  # The map that opened these dates, which the preceding step's link carries on.
  def map_to_return_to = (@map_scenario || id if @from == "map")

  def came_from
    input(type: "hidden", name: "from", value: @from) if @from
    input(type: "hidden", name: "map_scenario", value: @map_scenario) if @map_scenario
  end

  def choose
    form(action: dates_plan_path(plan_id, scenario_id: id), method: "get", class: "space-y-4") do
      came_from
      first_step? ? start_field : start_text
      date_field("ends_on", "Ends on", @draft[:ends_on] || @scenario[:ends_on])
      div(class: "flex flex-wrap items-center gap-2") do
        render(Components::Kit::Button.new(type: :submit, variant: changes? ? :outline : :solid, tone: changes? ? :neutral : :brand)) { "Preview" }
        render(Components::Kit::Button.new(variant: :ghost, href: back)) { "Cancel" } unless changes?
      end
    end
  end

  def start_field
    date_field("starts_on", "Starts on", @draft[:starts_on] || @scenario[:starts_on],
               hint: "The plan's base date is #{day(@plan[:base_on])}. A later start leaves Today running until then.")
  end

  def start_text
    div(data: { dates_start: id }) do
      p(class: "text-sm font-semibold text-default") { "Starts on" }
      p(class: "mt-1 text-sm text-default") do
        plain "#{day(@scenario[:starts_on])}, the day after "
        a(href: dates_plan_path(plan_id, scenario_id: parent[:scenario_id], from: @from, map_scenario: map_to_return_to), class: "underline") { parent[:name] }
        plain " ends. Change that step's end to move it."
      end
    end
  end

  def date_field(name, label_text, value, hint: nil)
    field_id = "scenario-#{name.dasherize}"
    div do
      label(for: field_id, class: "block text-sm font-semibold text-default") { label_text }
      p(id: "#{field_id}-hint", class: "mt-1 text-sm text-muted") { hint } if hint
      input(type: "date", id: field_id, name:, value:, required: true, aria: { describedby: ("#{field_id}-hint" if hint) },
            class: "#{Components::Kit::Field::INPUT} mt-2 max-w-xs")
    end
  end

  def changes?
    @preview && [ @preview[:starts_on], @preview[:ends_on] ] != [ @preview[:previous_starts_on], @preview[:previous_ends_on] ]
  end

  def confirm
    section(aria: { labelledby: "dates-preview-heading" }, class: "space-y-3 rounded-lg border border-default bg-default p-4",
            data: { dates_preview: @preview[:scenario_id] }) do
      h4(id: "dates-preview-heading", class: "text-sm font-semibold text-default") { "What this moves" }
      ul(class: "space-y-1 text-sm text-default") do
        moved(@preview)
        @preview[:moves].each { moved(it) }
      end
      p(class: "text-sm text-muted") { "Nothing else moves." } if @preview[:moves].empty?
      form(action: dates_plan_path(plan_id, scenario_id: id), method: "post", class: "flex flex-wrap items-center gap-2") do
        input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
        came_from
        input(type: "hidden", name: "starts_on", value: @preview[:starts_on]) if first_step?
        input(type: "hidden", name: "ends_on", value: @preview[:ends_on])
        render(Components::Kit::Button.new(type: :submit, tone: :brand)) { "Save dates" }
        render(Components::Kit::Button.new(variant: :ghost, href: back)) { "Cancel" }
      end
    end
  end

  def moved(move)
    scenario = @scenarios.find { it[:scenario_id] == move[:scenario_id] } || {}
    before = period(scenario.merge(starts_on: move[:previous_starts_on], ends_on: move[:previous_ends_on]))
    after = period(scenario.merge(starts_on: move[:starts_on], ends_on: move[:ends_on]))
    li(data: { dates_move: move[:scenario_id] }) do
      strong(class: "font-medium") { scenario_name(move[:scenario_id]) }
      plain ": #{before}, now #{after}."
    end
  end

  def period(scenario) = Views::Plans::ScenarioTable.period(scenario)

  def day(iso) = Date.iso8601(iso).strftime("%-d %b %Y")
end
