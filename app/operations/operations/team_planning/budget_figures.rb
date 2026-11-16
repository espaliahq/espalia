# frozen_string_literal: true

# How the budget reads send a budget's totals, so team_planning_budget and
# team_planning_timeline_figures give a step the same figure. A sum the
# caller may not see keeps its keys, each null, so its shape never says
# whether there was money to hide.
module Operations::TeamPlanning::BudgetFigures
  include Operations::TeamPlanning::CostFigures

  private

  def totals(totals, money: method(:money))
    { approved: { **money.(totals.approved), head_count: figure(totals.head_count) },
      funded: { **money.(totals.funded), **heads(totals.funded_heads) },
      remaining: { **money.(totals.remaining), head_count: figure(totals.remaining_head_count),
                   left_out: { mismatched_currencies: totals.remaining_left_out } },
      unfunded: { **money.(totals.unfunded), **heads(totals.unfunded_heads) }, over: over(totals.over) }
  end

  def over(over) = over && { money: over.money, heads: over.heads, mismatched_currencies: over.mismatched }

  def money(sum) = sum ? sum(sum) : { native: nil, converted: nil, missing: nil }

  def native_money(sum) = { native: sum&.native&.transform_values { decimal(it) } }

  def heads(heads) = { positions: heads.positions, fte: decimal(heads.fte) }

  def figure(value) = value.nil? ? nil : decimal(value)
end
