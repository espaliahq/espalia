# frozen_string_literal: true

# Forks a scenario in a plan: a step that follows its parent, or an
# alternative that covers its parent's period instead.
class Operations::TeamPlanning::ForkScenario < Operations::Base
  include Operations::TeamPlanning::PlanWrite
  include Operations::OrgGraph::DateParameter

  description "Fork a scenario in a Team Planning plan. relation 'then' adds the step after parent_id: it starts " \
              "the day after its parent ends (on the plan's base date after the baseline) and needs ends_on. " \
              "relation 'instead' adds an alternative to parent_id over the same period. parent_id defaults to the " \
              "baseline, whose id is the plan's. A parent has at most one 'then' step. " \
              "Refused unless the caller is one of the plan's editors."
  category :write
  approval :mcp_client

  parameter :plan_id, String, required: true
  parameter :parent_id, String, allow_blank: false
  parameter :relation, String, required: true, schema: { enum: ::TeamPlanning::PlanAggregate::RELATIONS }
  parameter :name, String, required: true, allow_blank: false,
    schema: { description: "What the scenario is, such as 'Lean Q1'. Don't put a person's name in it." }
  parameter :starts_on, String, allow_blank: false, schema: DATE_SCHEMA
  parameter :ends_on, String, allow_blank: false, schema: DATE_SCHEMA

  # @return [Hash] `{ plan_id, scenario_id, parent_id, relation, name, starts_on, ends_on }`
  def perform
    plan_id = plan_id!
    parent_id = scenario_id!(:parent_id) || plan_id
    scenario_id = SecureRandom.uuid_v7
    plan = refusing_bad_plans do
      handler.fork_scenario(plan_id, scenario_id, parent_id:, relation: params[:relation], name: params[:name],
                            starts_on: parse_date(:starts_on), ends_on: parse_date(:ends_on))
    end
    scenario = plan.scenarios.fetch(scenario_id)
    period = plan.period_of(scenario_id)
    { plan_id:, scenario_id:, parent_id:, relation: scenario.relation, name: scenario.name,
      starts_on: period.begin.iso8601, ends_on: period.end.iso8601 }
  end
end
