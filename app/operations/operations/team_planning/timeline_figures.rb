# frozen_string_literal: true

# The figures under each column of a timeline path, through
# {TeamPlanning::TimelineFigures} ([#452](https://github.com/espaliahq/espalia/issues/452)).
# A tool of its own, so team_planning_timeline stays free of money. It names
# no person, but its money follows the people in each seat, so the
# forgotten-person audit walks it.
class Operations::TeamPlanning::TimelineFigures < Operations::Base
  include Operations::TeamPlanning::PlanRead
  include Operations::TeamPlanning::BudgetFigures

  description "Get the figures for each column of one path of a Team Planning plan the caller is in, the path " \
              "team_planning_timeline lays out, root first. Each figure is the one the step's own tool gives. cost is " \
              "team_planning_cost's: for Today (basis run_rate) the yearly run rate of its seats, for a step (basis " \
              "period) its seats and forecast over its period. unpriced counts the seats left out of cost, for any " \
              "reason; team_planning_cost lists each with its reason. budget is team_planning_budget's total: approved, " \
              "funded and unfunded, each with its money and head count, and over; Today has none, as it has no period. " \
              "capacity is team_planning_capacity's total per capacity model, the step's own and its forecast. Figures " \
              "are decimal strings. A budget line's amount is pay: money is false for a caller without the plan's " \
              "see-pay right, who gets band midpoints in cost, every head count, and null for every budget amount, " \
              "native, converted and missing. #{PRICED_AS_ARCHIVED} #{OPEN_ENDED} Refused, as an unknown plan, unless " \
              "the caller is a member."
  category :read
  approval :none

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true, schema: { description: "The last step, or the plan's id for the baseline alone." }

  # @return [Hash] `{ plan_id, scenario_id, pay_view, money, reference_currency, steps }`, and an archived plan's
  #   archived_on, priced_on and note
  def perform
    plan = plan!
    scenario_id = scenario_id!(:scenario_id)
    result = refusing_bad_plans { ::TeamPlanning::TimelineFigures.new(context:, plan:, scenario_id:).call }
    { plan_id: plan.id, **priced_as_archived(plan), scenario_id:, pay_view: result.pay_view, money: result.money,
      reference_currency: result.reference_currency, steps: result.steps.map { step(it) } }
  end

  private

  def step(step)
    { scenario_id: step.scenario_id, basis: step.basis,
      period: { starts_on: step.period.begin.iso8601, ends_on: step.period.end.iso8601, open_ended: step.open_ended,
                horizon_months: step.horizon_months },
      cost: sum(step.cost), unpriced: step.unpriced, budget: step.budget && budget(step.budget),
      capacity: step.capacity.transform_values { decimal(it) } }
  end

  def budget(totals) = totals(totals).slice(:approved, :funded, :unfunded, :over)
end
