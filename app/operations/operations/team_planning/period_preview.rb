# frozen_string_literal: true

# What moving a step's period would move
# ([#404](https://github.com/espaliahq/espalia/issues/404)), before
# team_planning_set_scenario_period moves it. The plan page's Dates dialog
# shows it, so the rule for what follows a step lives only in the aggregate.
class Operations::TeamPlanning::PeriodPreview < Operations::Base
  include Operations::TeamPlanning::PlanRead
  include Operations::OrgGraph::DateParameter

  description "Preview moving the end of a 'then' scenario in a Team Planning plan the caller is in, and a first " \
              "step's start, before team_planning_set_scenario_period does it. Dates are inclusive. Returns the step " \
              "whose period moves (for the rest of a split, its agreed part), its new period and its previous one, and " \
              "`moves`: every other scenario whose period would change, with its period before and after. Each " \
              "step after it starts the day after the new end; its alternatives take the new period. Names come " \
              "from team_planning_scenarios. Refused as team_planning_set_scenario_period would refuse it, and, " \
              "as an unknown plan, unless the caller is a member."
  category :read
  approval :none

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true
  parameter :ends_on, String, required: true, allow_blank: false, schema: DATE_SCHEMA
  parameter :starts_on, String, allow_blank: false, schema: DATE_SCHEMA

  # @return [Hash] `{ plan_id, scenario_id, starts_on, ends_on, previous_starts_on, previous_ends_on, moves }`
  def perform
    plan = plan!
    aggregate = ::TeamPlanning::Repository.new.load_plan(plan.id)
    step, period, moves = refusing_bad_plans do
      aggregate.period_moves(scenario_id!(:scenario_id), ends_on: parse_date(:ends_on), starts_on: parse_date(:starts_on))
    end
    { plan_id: plan.id, scenario_id: step, starts_on: period.begin.iso8601, ends_on: period.end.iso8601,
      previous_starts_on: aggregate.period_of(step).begin.iso8601, previous_ends_on: aggregate.period_of(step).end.iso8601,
      moves: moves.map do |id, before, after|
        { scenario_id: id, starts_on: after.begin.iso8601, ends_on: after.end.iso8601,
          previous_starts_on: before.begin.iso8601, previous_ends_on: before.end.iso8601 }
      end }
  end
end
