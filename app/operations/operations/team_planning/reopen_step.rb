# frozen_string_literal: true

# Reopens the last step closed in a plan, so the plan stands as it did before
# the close ([#466](https://github.com/espaliahq/espalia/issues/466)).
class Operations::TeamPlanning::ReopenStep < Operations::Base
  include Operations::TeamPlanning::PlanWrite

  description "Reopen the last step closed in a Team Planning plan. The step and the alternatives it was taken over " \
              "can change again, and the steps after it stand on the plan's own base as before the close. Refused, " \
              "naming why, for a step that isn't closed or that isn't the last one closed, or unless the caller is an editor."
  category :write
  approval :mcp_client

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true

  # @return [Hash] `{ plan_id, scenario_id }`
  def perform
    plan_id = plan_id!
    scenario_id = scenario_id!(:scenario_id)
    refusing_bad_plans { handler.reopen_step(plan_id, scenario_id) }
    { plan_id:, scenario_id: }
  end
end
