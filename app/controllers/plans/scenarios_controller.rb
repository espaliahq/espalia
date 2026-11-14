# frozen_string_literal: true

# Forks and renames a plan's scenarios from its page (#271), through the same
# Operations the MCP tools use. A plan someone isn't in is a 404 here, as it is
# on the plan's page; a viewer is refused.
class Plans::ScenariosController < ApplicationController
  # POST /planning/:plan_id/scenarios
  def create
    authorize_editor
    draft = params.expect(scenario: [ :parent_id, :relation, :name, :ends_on ]).to_h.symbolize_keys.compact_blank
    scenario = Operations::TeamPlanning::ForkScenario.call(context: pundit_user, params: { plan_id:, **draft })
    redirect_to map_plan_path(plan_id, scenario: scenario[:scenario_id]), notice: "#{scenario[:name]} forked."
  rescue Operations::Base::ParameterError => e
    redirect_back_or_to plan_path(plan_id), alert: "Couldn't fork the scenario: #{e.message}"
  end

  # PATCH /planning/:plan_id/scenarios/:id
  def update
    authorize_editor
    scenario = Operations::TeamPlanning::RenameScenario.call(
      context: pundit_user, params: { plan_id:, scenario_id: params.expect(:id), name: params.expect(scenario: [ :name ])[:name] }
    )
    redirect_back_or_to plan_path(plan_id), notice: "Renamed to #{scenario[:name]}."
  rescue Operations::Base::ParameterError => e
    redirect_back_or_to plan_path(plan_id), alert: "Couldn't rename the scenario: #{e.message}"
  end

  private

  def plan_id = params.expect(:plan_id)

  # Reading the plan first makes one the caller isn't in a 404 rather than a
  # refusal, so the page never confirms it exists.
  def authorize_editor
    plan = Operations::TeamPlanning::Plan.call(context: pundit_user, params: { plan_id: })
    authorize TeamPlanningPlan.find(plan[:plan_id]), :update?, policy_class: PlanPolicy
  rescue Operations::Base::ParameterError => e
    raise ActiveRecord::RecordNotFound, e.message
  end
end
