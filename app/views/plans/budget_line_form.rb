# frozen_string_literal: true

# Adds a budget line to a scenario, or changes or cuts one it holds
# ([#411](https://github.com/espaliahq/espalia/issues/411)), through
# `team_planning_set_budget_line` and `team_planning_cut_budget_line`. The
# fields are the tenant budget page's; a change reaches the scenarios that
# follow this one. Today holds the organisation's budget, so it has no form.
class Views::Plans::BudgetLineForm < Views::Base
  include Views::Plans::ScenarioTab
  include Views::Tenant::BudgetLines::LineText
  include Views::Tenant::BudgetLines::LineFields

  # @param plan [Hash] from `team_planning_plan`
  # @param scenarios [Array<Hash>] from `team_planning_scenarios`
  # @param scenario_id [String] the scenario the line is in
  # @param values [Hash] the line as `team_planning_budget_lines` lists it, with anything typed merged in
  # @param roles [Array<FrameworkState::Role>] with their levels
  # @param countries [Array<String>]
  # @param budget_line_id [String, nil] the line being changed; nil to add one
  # @param error [String, nil] the operation's refusal
  def initialize(plan:, scenarios:, scenario_id:, values:, roles:, countries:, budget_line_id: nil, error: nil)
    @plan = plan
    @scenarios = scenarios
    @scenario_id = scenario_id
    @values = values
    @roles = roles
    @countries = countries
    @budget_line_id = budget_line_id
    @error = error
  end

  def view_template
    section(aria: { labelledby: "budget-line-heading" }, class: "max-w-3xl space-y-6", data: { budget_line_form: @budget_line_id || "new" }) do
      div do
        h3(id: "budget-line-heading", class: "text-base font-semibold text-default break-words") { heading }
        p(class: "mt-1 text-sm text-muted") do
          "The change reaches the scenarios that follow #{scenario_name(@scenario_id)}. Today keeps the budget the organisation approved."
        end
      end
      render(Components::Kit::Alert.new(tone: :danger, role: "alert", title: refusal_title)) { @error } if @error
      line_form
      cut_form if @budget_line_id
    end
  end

  private

  def plan_id = @plan[:plan_id]

  def heading
    return "Add a budget line to #{scenario_name(@scenario_id)}" unless @budget_line_id

    "Change #{line_name(@values)} in #{scenario_name(@scenario_id)}"
  end

  def refusal_title = @budget_line_id ? "Couldn't change the line" : "Couldn't add the line"

  def back_path = budget_plan_path(plan_id, scenario: @scenario_id)

  def line_form
    action = @budget_line_id ? update_budget_line_plan_path(plan_id, budget_line_id: @budget_line_id) : create_budget_line_plan_path(plan_id)
    form(action:, method: "post", class: "space-y-4", id: "budget-line-form") do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      input(type: "hidden", name: "_method", value: "patch") if @budget_line_id
      input(type: "hidden", name: "scenario_id", value: @scenario_id)
      line_fields(@values, roles: @roles, countries: @countries)
      div(class: "flex flex-wrap justify-end gap-2") do
        render Components::Kit::Button.new(variant: :outline, href: back_path) { "Cancel" }
        render Components::Kit::Button.new(tone: :brand, type: :submit, id: "budget-line-save") { @budget_line_id ? "Save the line" : "Add the line" }
      end
    end
  end

  def cut_form
    form(action: cut_budget_line_plan_path(plan_id, budget_line_id: @budget_line_id), method: "post",
         class: "flex flex-wrap items-center justify-between gap-3 border-t border-default pt-4", id: "budget-line-cut") do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      input(type: "hidden", name: "_method", value: "delete")
      input(type: "hidden", name: "scenario_id", value: @scenario_id)
      p(class: "text-sm text-muted") { "Cutting the line takes it out of this scenario and those that follow." }
      render Components::Kit::Button.new(variant: :outline, tone: :danger, type: :submit) { "Cut the line" }
    end
  end
end
