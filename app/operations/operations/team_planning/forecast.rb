# frozen_string_literal: true

# The forecast rows behind a scenario's cost and capacity
# ([#351](https://github.com/espaliahq/espalia/issues/351)), through
# {TeamPlanning::Forecast}. A row is an assumption, never a change: it has no
# id, so nothing can pin, clear or note it. It names no one.
class Operations::TeamPlanning::Forecast < Operations::Base
  include Operations::TeamPlanning::PlanRead

  SIGNIFICANT_DIGITS = 20

  description "List the forecast rows of a scenario of a Team Planning plan the caller is in: what the plan's " \
              "forecast rules assume about the scenario's period, beyond the changes it plans. Each row names its " \
              "kind (the rule that made it), its unit (null for none) and cost centre, the step it covers " \
              "(the scenario's period), the headcount it adds or takes away, its cost per currency and its capacity " \
              "per model. Attrition takes away the seats its leavers leave empty until their time to hire has passed, " \
              "including seats an earlier step's leavers left empty that are still empty in this step, " \
              "counting filled seats only, never an open position, a placeholder or a planned leaver, and priced at " \
              "the unit's average filled seat as the caller sees pay. These rows are the forecast part of team_planning_cost and team_planning_capacity, beside " \
              "their actual part, which means the baseline's figure, not actual pay. " \
              "A row has no id and is not a change: it can't be pinned, cleared, noted or listed among the changes; " \
              "change the rule to change it. The plan's own id, Today, has no period and so no rows. A step with no " \
              "end date forecasts over the plan's open_step_horizon rule in whole months from its start, with open_ended " \
              "true and horizon_months the months shown; otherwise open_ended is false and horizon_months null. Figures are " \
              "decimal strings. #{PRICED_TODAY} Refused, as an unknown plan, unless the caller is a member."
  category :read
  approval :none

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true, schema: { description: "A scenario of the plan; the plan's id gives no rows." }

  # @return [Hash] `{ plan_id, scenario_id, open_ended, horizon_months, rows }`
  def perform
    plan = plan!
    scenario_id = scenario_id!(:scenario_id)
    cost = nil
    rows = refusing_bad_plans do
      cost = ::TeamPlanning::Cost.new(context:, plan:, scenario_id:).call(at_end: false)
      capacity = ::TeamPlanning::Capacity.split(context:, plan:, scenario_id:)
      names = cost.scenario.map.units.to_h { [ it.id, it.name ] }
      measured = capacity.forecast.index_by { key(it) }
      cost.forecast.rows.map { row(it.with(capacity: measured[key(it)]&.capacity || {}), names) }
    end
    { plan_id: plan.id, **priced_today(plan), scenario_id:, open_ended: cost.open_ended, horizon_months: cost.horizon_months, rows: }
  end

  private

  # Cost and capacity forecast the same rows, each pricing only its own figure.
  def key(row) = [ row.kind, row.unit_id, row.cost_centre, row.starts_on ]

  def row(row, names)
    { kind: row.kind, unit_id: row.unit_id, unit_name: names[row.unit_id], cost_centre: row.cost_centre,
      starts_on: row.starts_on.iso8601, ends_on: row.ends_on.iso8601, headcount: decimal(row.headcount),
      cost: figures(row.cost), capacity: figures(row.capacity) }
  end

  def figures(amounts) = amounts.transform_values { decimal(it) }

  def decimal(value) = BigDecimal(value, SIGNIFICANT_DIGITS).to_s("F").delete_suffix(".0")
end
