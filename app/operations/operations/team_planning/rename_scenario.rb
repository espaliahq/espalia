# frozen_string_literal: true

# Renames a scenario. The baseline keeps its place as today, so it has no
# name to change.
class Operations::TeamPlanning::RenameScenario < Operations::Base
  include Operations::TeamPlanning::PlanWrite

  description "Rename a scenario in a Team Planning plan. Names are plain text kept in the plan's history, so " \
              "leave people's names out of them. Refused for the baseline, or unless the caller is one of its editors."
  category :write
  approval :mcp_client

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true
  parameter :name, String, required: true, allow_blank: false

  # @return [Hash] `{ plan_id, scenario_id, name }`
  def perform
    plan_id = plan_id!
    scenario_id = scenario_id!(:scenario_id)
    plan = refusing_bad_plans { handler.rename_scenario(plan_id, scenario_id, name: params[:name]) }
    { plan_id:, scenario_id:, name: plan.scenarios.fetch(scenario_id).name }
  end
end
