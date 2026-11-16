# frozen_string_literal: true

# The plan page's "New scenario" and "Edit scenario" dialogs (#271, #272), one
# of each per page, for editors. The header button, each row's menu and the
# map's picker open them, passing the scenario they start from in the
# trigger's dataset, which the `scenario-fork-form` and `rename-form`
# controllers read. Both forms post to {Plans::ScenariosController}, which
# lands a fork on its map and sends an edit back to the page it came from.
class Views::Plans::ScenarioDialogs < Views::Base
  FORK_ID = "fork-scenario-modal"
  EDIT_ID = "edit-scenario-modal"

  # The data a trigger carries to open the fork dialog from a scenario.
  #
  # @param parent_id [String]
  # @return [Hash]
  def self.fork_trigger(parent_id)
    { action: "click->modal#open", modal_target_id: FORK_ID, scenario_fork_parent: parent_id }
  end

  # The data a trigger carries to open the edit dialog on a scenario.
  #
  # @param url [String] the scenario's update path
  # @param scenario [Hash] from `team_planning_scenarios`
  # @return [Hash]
  def self.edit_trigger(url, scenario)
    { action: "click->modal#open", modal_target_id: EDIT_ID, rename_action: url, rename_name: scenario[:name],
      rename_description: scenario[:description].to_s }
  end

  # Where a new scenario starts when nothing else says: the end of the chain
  # of scenarios that follow today, so it carries the plan on.
  #
  # @param plan_id [String]
  # @param scenarios [Array<Hash>]
  # @return [String] a scenario id
  def self.default_parent(plan_id, scenarios)
    nexts = next_steps(scenarios)
    id = plan_id
    seen = Set.new
    id = nexts[id] while nexts.key?(id) && seen.add?(id)
    id
  end

  # Each scenario that has one, with the scenario that comes after it. A
  # scenario has at most one. The agreed part of a split step has the rest,
  # which sits on it, so it can't take a next step of its own.
  #
  # @param scenarios [Array<Hash>]
  # @return [Hash{String => String}]
  def self.next_steps(scenarios) = scenarios.select { onward?(it) }.to_h { [ it[:parent_id], it[:scenario_id] ] }

  # Whether a scenario carries its parent's path on: as the next step, or as
  # the rest of a split step. The baseline carries nothing on.
  #
  # @param scenario [Hash] from `team_planning_scenarios`
  # @return [Boolean]
  def self.onward?(scenario)
    case scenario[:relation]
    in "then" | "on" then true
    in "instead" | nil then false
    end
  end

  # @param plan_id [String]
  # @param scenarios [Array<Hash>] from `team_planning_scenarios`, baseline first
  def initialize(plan_id:, scenarios:)
    @plan_id = plan_id
    @scenarios = scenarios
    @next_steps = self.class.next_steps(scenarios)
  end

  def view_template
    render Components::Kit::Modal.new(id: FORK_ID, title: "New scenario", size: :md, standalone: false,
                                      dirty_guard: "Discard this scenario?") do |m|
      m.body { fork_form }
    end
    render Components::Kit::Modal.new(id: EDIT_ID, title: "Edit scenario", size: :md, standalone: false,
                                      dirty_guard: "Discard your changes?") do |m|
      m.body { edit_form }
    end
  end

  private

  def fork_form
    form(action: plan_scenarios_path(@plan_id), method: "post", class: "space-y-4",
         data: { controller: "scenario-fork-form", scenario_fork_form_baseline_value: @plan_id,
                 action: "turbo:submit-end->modal#submitted" }) do
      authenticity_token
      field("fork-scenario-parent", "Starts from") do
        select(id: "fork-scenario-parent", name: "scenario[parent_id]", class: Components::Kit::Field::SELECT,
               data: { scenario_fork_form_target: "parent", action: "change->scenario-fork-form#sync" }) do
          Views::Plans::ScenarioTable.tree(@scenarios).each do |scenario, depth|
            option(value: scenario[:scenario_id], data: { followed: followed?(scenario).to_s, **open_after(scenario) }) do
              "#{'· ' * depth}#{scenario_name(scenario)}"
            end
          end
        end
      end
      relation_choice
      field("fork-scenario-name", "Name", hint: "What the scenario is, such as Lean Q1. Leave people's names out.") do
        input(id: "fork-scenario-name", type: "text", name: "scenario[name]", required: true, pattern: ".*\\S.*",
              maxlength: TeamPlanning::PlanAggregate::NAME_LIMIT, autocomplete: "off", title: "The name can't be blank",
              aria: { describedby: "fork-scenario-name-hint" }, class: Components::Kit::Field::INPUT)
      end
      starts_on_field
      ends_on_field
      actions("Create scenario", data: { scenario_fork_form_target: "submit" })
    end
  end

  # A first step can start later than the plan's base date: Today then
  # carries on until it starts. A step after one with no end date says when it
  # starts, and that step ends the day before.
  def starts_on_field
    base_on = @scenarios.find { it[:scenario_id] == @plan_id }&.dig(:starts_on)
    div(hidden: true, data: { scenario_fork_form_target: "startsOnField" }) do
      label(for: "fork-scenario-starts-on", class: "block text-sm font-medium text-default mb-1") { "Starts on" }
      input(id: "fork-scenario-starts-on", type: "date", name: "scenario[starts_on]", value: base_on, min: base_on, disabled: true,
            aria: { describedby: "fork-scenario-starts-on-first" }, class: Components::Kit::Field::INPUT,
            data: { scenario_fork_form_target: "startsOn" })
      p(id: "fork-scenario-starts-on-first", class: "mt-1 text-xs text-muted", data: { scenario_fork_form_target: "firstHint" }) do
        "On or after the plan's base date#{", #{day(base_on)}" if base_on}. Today continues until then."
      end
      p(id: "fork-scenario-starts-on-open", class: "mt-1 text-xs text-muted", hidden: true, data: { scenario_fork_form_target: "openHint" }) do
        "The step before it has no end date, so say when this one starts. That step then ends the day before."
      end
    end
  end

  def ends_on_field
    div(data: { scenario_fork_form_target: "endsOnField" }) do
      field("fork-scenario-ends-on", "Ends on", hint: "Its last day. A step after another starts the day after that one ends.") do
        input(id: "fork-scenario-ends-on", type: "date", name: "scenario[ends_on]", required: true,
              aria: { describedby: "fork-scenario-ends-on-hint" }, class: Components::Kit::Field::INPUT,
              data: { scenario_fork_form_target: "endsOn" })
      end
      div(class: "mt-2 flex items-start gap-2") do
        input(id: "fork-scenario-no-end", type: "checkbox", class: "mt-0.5 #{Components::Kit::Field::CHECKBOX}",
              aria: { describedby: "fork-scenario-no-end-hint" },
              data: { scenario_fork_form_target: "noEnd", action: "change->scenario-fork-form#sync" })
        label(for: "fork-scenario-no-end", class: "text-sm") do
          span(class: "font-medium text-default") { "No end date" }
          span(id: "fork-scenario-no-end-hint", class: "block text-muted") do
            "It runs until a step comes after it. Cost and budget show a set number of months from its start, and say how many."
          end
        end
      end
    end
  end

  # The start a step after this one needs when its period has no end: a day
  # after that period starts.
  def open_after(scenario)
    return {} if scenario[:scenario_id] == @plan_id

    owner = Views::Plans::ScenarioTable.period_owner(scenario, @scenarios)
    return {} if owner.nil? || owner[:ends_on]

    { open: "true", earliest_start: (Date.iso8601(owner[:starts_on]) + 1).iso8601 }
  end

  def day(iso) = Date.iso8601(iso).strftime("%-d %b %Y")

  def followed?(scenario) = @next_steps.key?(scenario[:scenario_id])

  def relation_choice
    fieldset do
      legend(class: "block text-sm font-medium text-default mb-1") { "It comes" }
      div(class: "space-y-2") do
        relation_option("then", "After it", "The next step, from the day it ends.", checked: true)
        relation_option("instead", "Instead of it", "An alternative over the same period.")
      end
      p(class: "mt-2 text-sm text-warning", hidden: true, data: { scenario_fork_form_target: "blocked" }) do
        "Today already has a scenario after it and has nothing to replace. Start from a scenario instead."
      end
    end
  end

  def relation_option(value, title, detail, checked: false)
    id = "fork-scenario-relation-#{value}"
    div(class: "flex items-start gap-2") do
      input(id:, type: "radio", name: "scenario[relation]", value:, checked:, class: "mt-0.5 #{Components::Kit::Field::RADIO}",
            data: { scenario_fork_form_target: "relation", action: "change->scenario-fork-form#sync" })
      label(for: id, class: "text-sm") do
        span(class: "font-medium text-default") { title }
        span(class: "block text-muted") { detail }
      end
    end
  end

  def edit_form
    form(method: "post", class: "space-y-4",
         data: { controller: "rename-form", action: "turbo:submit-end->modal#submitted" }) do
      authenticity_token
      input(type: "hidden", name: "_method", value: "patch")
      field("edit-scenario-name", "Name", hint: "Leave people's names out.") do
        input(id: "edit-scenario-name", type: "text", name: "scenario[name]", required: true, pattern: ".*\\S.*",
              maxlength: TeamPlanning::PlanAggregate::NAME_LIMIT, autocomplete: "off", title: "The name can't be blank",
              aria: { describedby: "edit-scenario-name-hint" }, class: Components::Kit::Field::INPUT,
              data: { rename_form_target: "name" })
      end
      field("edit-scenario-description", "Description",
            hint: "What this scenario is for, such as hiring two seniors before Q3. Deleting the plan deletes it.") do
        textarea(id: "edit-scenario-description", name: "scenario[description]", rows: "3",
                 maxlength: TeamPlanning::PlanAggregate::DESCRIPTION_LIMIT,
                 aria: { describedby: "edit-scenario-description-hint" }, class: Components::Kit::Field::TEXTAREA,
                 data: { rename_form_target: "description" })
      end
      actions("Save")
    end
  end

  def field(id, text, hint: nil)
    div do
      label(for: id, class: "block text-sm font-medium text-default mb-1") { text }
      yield
      p(id: "#{id}-hint", class: "mt-1 text-xs text-muted") { hint } if hint
    end
  end

  def actions(submit, data: {})
    div(class: "flex items-center gap-3") do
      render Components::Kit::Button.new(tone: :brand, type: :submit, data:) { submit }
      render Components::Kit::Button.new(variant: :outline, data: { action: "click->modal#close" }) { "Cancel" }
    end
  end

  def authenticity_token
    input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
  end

  def scenario_name(scenario) = scenario[:parent_id].nil? ? "Today" : scenario[:name]
end
