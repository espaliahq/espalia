# frozen_string_literal: true

# Forks and edits a plan's scenarios from its page (#271, #272), through the same
# Operations the MCP tools use. A plan someone isn't in is a 404 here, as it is
# on the plan's page; a viewer is refused.
class Plans::ScenariosController < ApplicationController
  # POST /planning/:plan_id/scenarios
  def create
    authorize_editor
    draft = params.expect(scenario: [ :parent_id, :relation, :name, :starts_on, :ends_on ]).to_h.symbolize_keys.compact_blank
    scenario = Operations::TeamPlanning::ForkScenario.call(context: pundit_user, params: { plan_id:, **draft })
    redirect_to map_plan_path(plan_id, scenario: scenario[:scenario_id]), notice: "#{scenario[:name]} forked."
  rescue Operations::Base::ParameterError => e
    redirect_back_or_to plan_path(plan_id), alert: "Couldn't fork the scenario: #{e.message}"
  end

  # PATCH /planning/:plan_id/scenarios/:id
  #
  # Renames and describes from one dialog. Each field is its own write, so a
  # rename can land when a description is refused; the alert says so.
  def update
    authorize_editor
    fields = params.expect(scenario: [ :name, :description ])
    scenario = { plan_id:, scenario_id: params.expect(:id) }
    name = Operations::TeamPlanning::RenameScenario.call(context: pundit_user, params: { **scenario, name: fields[:name] })[:name] if fields.key?(:name)
    if fields.key?(:description)
      begin
        Operations::TeamPlanning::DescribeScenario.call(context: pundit_user, params: { **scenario, description: fields[:description] })
      rescue Operations::Base::ParameterError => e
        raise unless name

        return redirect_back_or_to plan_path(plan_id), alert: "Saved #{name}, but couldn't save its description: #{e.message}"
      end
    end
    redirect_back_or_to plan_path(plan_id), notice: name ? "Saved #{name}." : "Scenario saved."
  rescue Operations::Base::ParameterError => e
    redirect_back_or_to plan_path(plan_id), alert: "Couldn't save the scenario: #{e.message}"
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
