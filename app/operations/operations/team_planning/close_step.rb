# frozen_string_literal: true

# Closes a step of a plan once its period has ended
# ([#466](https://github.com/espaliahq/espalia/issues/466)).
class Operations::TeamPlanning::CloseStep < Operations::Base
  include Operations::TeamPlanning::PlanWrite

  description "Close a step of a Team Planning plan once its period has ended, the step taken on the timeline. " \
              "Steps close in timeline order, from the day after the step's last day; a step with no end date, the " \
              "baseline and an alternative another step closed in place of can't close. Once closed, the step and the " \
              "alternatives it wasn't taken over can't change, and the steps after it stand on the organisation as the " \
              "Org Graph holds it the day after the step ends, with every change the closed steps planned that hadn't " \
              "happened by then carried over. team_planning_reopen_step undoes it. Refused, naming why, unless the " \
              "caller is an editor."
  category :write
  approval :mcp_client

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true

  # @return [Hash] `{ plan_id, scenario_id, ends_on }`, ends_on the step's last day
  def perform
    plan_id = plan_id!
    scenario_id = scenario_id!(:scenario_id)
    plan = refusing_bad_plans { handler.close_step(plan_id, scenario_id) }
    { plan_id:, scenario_id:, ends_on: plan.closed_steps.to_h.fetch(scenario_id).iso8601 }
  end
end
