# frozen_string_literal: true

# A scenario's four budget numbers, through {TeamPlanning::Budget}
# ([#369](https://github.com/espaliahq/espalia/issues/369)). Funded and
# unfunded price seats as team_planning_cost does for the same caller, so a
# member without the see-pay right gets midpoints throughout and nothing
# derived from actual pay. It names no person, but its money follows the
# people in each position, so the forgotten-person audit walks it.
class Operations::TeamPlanning::Budget < Operations::Base
  include Operations::TeamPlanning::PlanRead
  include Operations::TeamPlanning::CostFigures

  description "Get the four budget numbers for a scenario of a Team Planning plan the caller is in: approved, " \
              "funded, remaining and unfunded. basis is the budget_basis rule: inclusive (base pay plus on-cost, the " \
              "default) or base_only, and every money figure is on it. Approved is each budget line's amount, made " \
              "yearly, over the days its period overlaps the scenario's out of 365, in its own currency, beside its " \
              "head_count; a line with no amount approves null, never zero. Funded is what the seats team_planning_cost " \
              "prices for this caller cost, each at the share its position draws on a line (as team_planning_funding " \
              "derives or sets it), for the days of the seat the line's period covers, so it follows pay_view. Unfunded is " \
              "the rest: the share and days no held draw funds, seats in no position, and forecast rows, which count as " \
              "their kind prices them on either basis. Funded plus unfunded is team_planning_cost's scenario total, per " \
              "currency, on an inclusive basis. Remaining is approved less funded in the line's own currency, and " \
              "head_count less the FTE drawn. Money stays per currency: a line drawn on in another currency lists it in " \
              "mismatched_currencies, never converted, and its remaining amount is null, as approved less only the part in " \
              "its own currency would overstate it; a remaining total leaves such lines out and lists their ids under " \
              "remaining.left_out.mismatched_currencies, so a total with any listed is not complete. Only the scenario-wide total and forecast carry `converted` and `missing`, in the " \
              "reference currency at the period's start; every group sum is `native` alone. cost_centres (by the cost " \
              "centre a line was approved for, null for none; unfunded money by the seat's cost centre, unfunded head " \
              "count by the position's) carry all four; budget_lines carry approved, funded and remaining; units carry " \
              "funded and unfunded. Head counts are positions and FTE: a line or cost centre counts " \
              "each position drawing on it once, at the FTE it draws, while units and the total count the positions " \
              "funded whole, as team_planning_funding does, so funded and unfunded add up to every position. A position with a seat no pay band prices still counts in head count and is listed under " \
              "unpriced with no money; so is one whose on-cost is refused, unless the basis is base_only, which funds its base. Figures are decimal strings. The baseline has no period, so it can't be the " \
              "scenario. strictness is the budget_strictness rule, with the preset it equals or null, and its scope " \
              "decides where the budget is held: each budget line, each cost centre or the total (organisation) carries " \
              "over, and the rest carry null. over.money lists the currencies it spends more of than its lines approve " \
              "(null when the limit is heads or no line approves an amount); over.heads says whether it holds more FTE " \
              "than its lines count (null when the limit is money or no line states a head count). A cost centre or the " \
              "total spends its unfunded money and heads too. Nothing is converted to judge it: a currency no line " \
              "approves goes in over.mismatched_currencies, never counted. Refused, as an unknown plan, unless the caller is a member."
  category :read
  approval :none

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true, schema: { description: "A scenario of the plan; not the plan's id, as the baseline has no period." }

  # @return [Hash] `{ plan_id, scenario_id, basis, strictness, period, pay_view, reference_currency, total, forecast,
  #   budget_lines, cost_centres, units, unpriced }`
  def perform
    plan = plan!
    scenario_id = scenario_id!(:scenario_id)
    report = refusing_bad_plans { ::TeamPlanning::Budget.new(context:, plan:, scenario_id:).call }
    { plan_id: plan.id, scenario_id:, basis: report.basis, strictness: ::TeamPlanning::RuleKinds::BudgetStrictness.describe(report.strictness), period: period(report), pay_view: report.pay_view,
      reference_currency: report.reference_currency, total: totals(report.totals), forecast: sum(report.forecast),
      budget_lines: report.lines.map { line(it) },
      cost_centres: report.cost_centres.map { |cost_centre, totals| { cost_centre:, **totals(totals, money: method(:native)) } },
      units: report.units.map { |unit_id, totals| { unit_id:, **unit(totals) } },
      unpriced: report.unpriced.map(&:to_h) }
  end

  private

  def line(line)
    budget_line = line.line
    { budget_line_id: budget_line.id, cost_centre: budget_line.cost_centre.presence, currency: budget_line.currency,
      approved: { amount: figure(line.approved), head_count: figure(budget_line.head_count) },
      funded: { native: line.funded.transform_values { decimal(it) }, **heads(line.funded_heads) },
      remaining: { amount: figure(line.remaining), head_count: figure(line.remaining_head_count) },
      mismatched_currencies: line.mismatched, over: over(line.over) }
  end

  def totals(totals, money: method(:sum))
    { approved: { **money.(totals.approved), head_count: figure(totals.head_count) },
      funded: { **money.(totals.funded), **heads(totals.funded_heads) },
      remaining: { **money.(totals.remaining), head_count: figure(totals.remaining_head_count),
                   left_out: { mismatched_currencies: totals.remaining_left_out } },
      unfunded: { **money.(totals.unfunded), **heads(totals.unfunded_heads) }, over: over(totals.over) }
  end

  def over(over) = over && { money: over.money, heads: over.heads, mismatched_currencies: over.mismatched }

  def unit(totals)
    { funded: { **native(totals.funded), **heads(totals.funded_heads) }, unfunded: { **native(totals.unfunded), **heads(totals.unfunded_heads) } }
  end

  def native(sum) = { native: sum.native.transform_values { decimal(it) } }

  def heads(heads) = { positions: heads.positions, fte: decimal(heads.fte) }

  def figure(value) = value.nil? ? nil : decimal(value)
end
