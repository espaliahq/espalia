# frozen_string_literal: true

# Moves the end of a step in a plan, and the start of a first step. Every step
# after it starts from the new end, and its alternatives cover the new period.
class Operations::TeamPlanning::SetScenarioPeriod < Operations::Base
  include Operations::TeamPlanning::PlanWrite
  include Operations::OrgGraph::DateParameter

  description "Move the end of a 'then' scenario in a Team Planning plan. Every step after it starts the day after " \
              "the new end, and its alternatives take the new period. The first step after the baseline may also " \
              "move its start with starts_on, on or after the plan's base date; the days before it read as today. " \
              "A later step's start follows the step before it, so starts_on is refused for one unless it repeats that start. Refused if a " \
              "later step would end before it starts, naming that step, if someone's last day would fall outside " \
              "the scenario they leave in, or unless the caller is an editor."
  category :write
  approval :mcp_client

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true
  parameter :ends_on, String, required: true, allow_blank: false, schema: DATE_SCHEMA
  parameter :starts_on, String, allow_blank: false, schema: DATE_SCHEMA

  # @return [Hash] `{ plan_id, scenario_id, starts_on, ends_on }`
  def perform
    plan_id = plan_id!
    scenario_id = scenario_id!(:scenario_id)
    plan = refusing_bad_plans do
      handler.set_scenario_period(plan_id, scenario_id, ends_on: parse_date(:ends_on), starts_on: parse_date(:starts_on))
    end
    period = plan.period_of(scenario_id)
    { plan_id:, scenario_id:, starts_on: period.begin.iso8601, ends_on: period.end.iso8601 }
  end
end
