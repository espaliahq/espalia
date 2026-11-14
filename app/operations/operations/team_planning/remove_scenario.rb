# frozen_string_literal: true

# Removes a scenario no other scenario forks from.
class Operations::TeamPlanning::RemoveScenario < Operations::Base
  include Operations::TeamPlanning::PlanWrite

  description "Remove a scenario from a Team Planning plan. It cannot be restored. Refused for the baseline, " \
              "for a scenario others fork from (remove those first), or unless the caller is one of its editors."
  category :destructive

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true

  # @return [Hash] `{ plan_id, scenario_id, removed }`
  def perform
    plan_id = plan_id!
    scenario_id = scenario_id!(:scenario_id)
    refusing_bad_plans { handler.remove_scenario(plan_id, scenario_id) }
    { plan_id:, scenario_id:, removed: true }
  end
end
