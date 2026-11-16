# frozen_string_literal: true

# A scenario's budget lines [#302](https://github.com/espaliahq/espalia/issues/302):
# the organisation's approved lines, read live, with the changes along the
# scenario's chain on top. This is the only way a plan member reads the
# organisation's budget, and only through a plan they are in.
#
# A change to a line the organisation has since removed is listed under
# `orphaned`, never dropped. An amount is pay
# ([#367](https://github.com/espaliahq/espalia/issues/367)): a member without
# the see-pay right gets each line's amount, currency and period as null, the
# period with them as only an amount has one, so a line with a hidden amount
# reads exactly as one with none.
class Operations::TeamPlanning::BudgetLines < Operations::Base
  include Operations::TeamPlanning::PlanRead

  description "List the budget lines in a scenario of a Team Planning plan the caller is in: the organisation's " \
              "approved lines with this scenario's changes, and those it inherits, on top. source is 'tenant' for a " \
              "line as the organisation approved it, 'changed' for one the plan changed, and 'plan' for one the plan " \
              "added. An amount keeps its own currency and period, a year or a month, and is never converted; a line " \
              "with only a head count has a null amount, never zero. Figures are decimal strings. orphaned lists each " \
              "change that sets or cuts a line the organisation has since removed, with `kind` set or cut; " \
              "team_planning_attention flags each. A budget amount is pay: money is false for a caller without the plan's " \
              "see-pay right, and every line's amount, currency and period is then null. #{PRICED_AS_ARCHIVED} Refused, as an unknown plan, unless the caller is a member."
  category :read
  approval :none

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true, schema: { description: "The scenario, or the plan's id for the baseline." }

  # @return [Hash] `{ plan_id, scenario_id, money, budget_lines, orphaned }`
  def perform
    plan = plan!
    scenario_id = scenario_id!(:scenario_id)
    map = refusing_bad_plans { ::TeamPlanning::Resolution.new(context:, plan:, scenario_id:).structure }
    @money = ::TeamPlanning::Budget.money_shown?(context:, plan:)
    { plan_id: plan.id, **priced_as_archived(plan), scenario_id:, money: @money, budget_lines: map.budget_lines.map { line_payload(it) },
      orphaned: map.orphaned_lines.map { |budget_line_id, kind| { budget_line_id:, kind: } } }
  end

  private

  def line_payload(line)
    {
      budget_line_id: line.id, source: line.source,
      starts_on: line.starts_on.iso8601, ends_on: line.ends_on.iso8601, origin: line.origin, approved_on: line.approved_on&.iso8601,
      amount: (::BudgetLine.figure_of(line.revealed_amount) if @money), currency: (line.currency if @money), period: (line.period if @money),
      head_count: ::BudgetLine.figure_of(line.head_count),
      role_id: line.role_id, level_id: line.level_id, role: line.role_name, level_name: line.level_name,
      location: line.location.presence, cost_centre: line.cost_centre.presence
    }
  end
end
