# frozen_string_literal: true

# What moving a step's period would move
# ([#404](https://github.com/espaliahq/espalia/issues/404)), before
# team_planning_set_scenario_period moves it. The Dates page
# shows it, so the rule for what follows a step lives only in the aggregate.
class Operations::TeamPlanning::PeriodPreview < Operations::Base
  include Operations::TeamPlanning::PlanRead
  include Operations::OrgGraph::DateParameter

  description "Preview moving the end of a 'then' scenario in a Team Planning plan the caller is in, and a first " \
              "step's start, before team_planning_set_scenario_period does it. Dates are inclusive, and a null ends_on means no end date. Returns the step " \
              "whose period moves (for the rest of a split, its agreed part), its new period and its previous one, and " \
              "`moves`: every other scenario whose period would change, with its period before and after. Each " \
              "step after it starts the day after the new end; its alternatives take the new period. Names come " \
              "from team_planning_scenarios. Refused as team_planning_set_scenario_period would refuse it, and, " \
              "as an unknown plan, unless the caller is a member."
  category :read
  approval :none

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true
  parameter :ends_on, String, required: true, schema: DATE_OR_BLANK_SCHEMA.merge(
    description: "The step's last day, YYYY-MM-DD, or an empty string for no end date, which only the last step on a line may have."
  )
  parameter :starts_on, String, allow_blank: false, schema: DATE_SCHEMA

  # @return [Hash] `{ plan_id, scenario_id, starts_on, ends_on, previous_starts_on, previous_ends_on, moves }`
  def perform
    plan = plan!
    aggregate = ::TeamPlanning::Repository.new.load_plan(plan.id)
    step, period, moves = refusing_bad_plans do
      aggregate.period_moves(scenario_id!(:scenario_id), ends_on: parse_date(:ends_on), starts_on: parse_date(:starts_on))
    end
    before = aggregate.period_of(step)
    { plan_id: plan.id, scenario_id: step, **dates(period), **dates(before, "previous_"),
      moves: moves.map { |id, before, after| { scenario_id: id, **dates(after), **dates(before, "previous_") } } }
  end

  private

  def dates(period, prefix = "")
    { "#{prefix}starts_on": period.begin.iso8601, "#{prefix}ends_on": period.end&.iso8601 }
  end
end
