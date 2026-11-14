# frozen_string_literal: true

# The plan page's "New scenario" and "Rename scenario" dialogs (#271), one of
# each per page, for editors. The header button, each row's menu and the map's
# picker open them, passing the scenario they start from in the trigger's
# dataset, which the `scenario-fork-form` and `rename-form`
# controllers read. Both forms post to {Plans::ScenariosController}, which
# lands a fork on its map and sends a rename back to the page it came from.
class Views::Plans::ScenarioDialogs < Views::Base
  FORK_ID = "fork-scenario-modal"
  RENAME_ID = "rename-scenario-modal"

  # The data a trigger carries to open the fork dialog from a scenario.
  #
  # @param parent_id [String]
  # @return [Hash]
  def self.fork_trigger(parent_id)
    { action: "click->modal#open", modal_target_id: FORK_ID, scenario_fork_parent: parent_id }
  end

  # The data a trigger carries to open the rename dialog on a scenario.
  #
  # @param url [String] the scenario's update path
  # @param name [String] its current name
  # @return [Hash]
  def self.rename_trigger(url, name)
    { action: "click->modal#open", modal_target_id: RENAME_ID, rename_action: url, rename_name: name }
  end

  # Where a new scenario starts when nothing else says: the end of the chain
  # of scenarios that follow today, so it carries the plan on.
  #
  # @param plan_id [String]
  # @param scenarios [Array<Hash>]
  # @return [String] a scenario id
  def self.default_parent(plan_id, scenarios)
    nexts = scenarios.select { it[:relation] == "then" }.to_h { [ it[:parent_id], it[:scenario_id] ] }
    id = plan_id
    seen = Set.new
    id = nexts[id] while nexts.key?(id) && seen.add?(id)
    id
  end

  # @param plan_id [String]
  # @param scenarios [Array<Hash>] from `team_planning_scenarios`, baseline first
  def initialize(plan_id:, scenarios:)
    @plan_id = plan_id
    @scenarios = scenarios
  end

  def view_template
    render Components::Kit::Modal.new(id: FORK_ID, title: "New scenario", size: :md, standalone: false,
                                      dirty_guard: "Discard this scenario?") do |m|
      m.body { fork_form }
    end
    render Components::Kit::Modal.new(id: RENAME_ID, title: "Rename scenario", size: :sm, standalone: false) do |m|
      m.body { rename_form }
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
            option(value: scenario[:scenario_id], data: { followed: followed?(scenario).to_s }) { "#{'· ' * depth}#{scenario_name(scenario)}" }
          end
        end
      end
      relation_choice
      field("fork-scenario-name", "Name", hint: "What the scenario is, such as Lean Q1. Leave people's names out.") do
        input(id: "fork-scenario-name", type: "text", name: "scenario[name]", required: true, pattern: ".*\\S.*",
              maxlength: TeamPlanning::PlanAggregate::NAME_LIMIT, autocomplete: "off", title: "The name can't be blank",
              aria: { describedby: "fork-scenario-name-hint" }, class: Components::Kit::Field::INPUT)
      end
      div(data: { scenario_fork_form_target: "endsOnField" }) do
        field("fork-scenario-ends-on", "Ends on", hint: "It starts the day after the scenario it follows ends.") do
          input(id: "fork-scenario-ends-on", type: "date", name: "scenario[ends_on]", required: true,
                aria: { describedby: "fork-scenario-ends-on-hint" }, class: Components::Kit::Field::INPUT,
                data: { scenario_fork_form_target: "endsOn" })
        end
      end
      actions("Create scenario", data: { scenario_fork_form_target: "submit" })
    end
  end

  def followed?(scenario) = @scenarios.any? { it[:parent_id] == scenario[:scenario_id] && it[:relation] == "then" }

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

  def rename_form
    form(method: "post", class: "space-y-4",
         data: { controller: "rename-form", action: "turbo:submit-end->modal#submitted" }) do
      authenticity_token
      input(type: "hidden", name: "_method", value: "patch")
      field("rename-scenario-name", "Name", hint: "Leave people's names out.") do
        input(id: "rename-scenario-name", type: "text", name: "scenario[name]", required: true, pattern: ".*\\S.*",
              maxlength: TeamPlanning::PlanAggregate::NAME_LIMIT, autocomplete: "off", title: "The name can't be blank",
              aria: { describedby: "rename-scenario-name-hint" }, class: Components::Kit::Field::INPUT,
              data: { rename_form_target: "name" })
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
