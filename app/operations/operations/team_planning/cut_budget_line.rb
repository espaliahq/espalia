# frozen_string_literal: true

# Cuts a budget line from a scenario, as a BudgetLineCut change
# [#302](https://github.com/espaliahq/espalia/issues/302). It shares the
# line's facet, so team_planning_set_budget_line brings the line back, and
# undo, redo and clear work as for any change.
class Operations::TeamPlanning::CutBudgetLine < Operations::Base
  include Operations::TeamPlanning::BudgetLineWrite

  KIND = ::TeamPlanning::Events::BudgetLineCut

  description "Cut a budget line from a scenario of a Team Planning plan, by budget_line_id from " \
              "team_planning_budget_lines. The scenarios that follow lose it too. Setting the line again brings it " \
              "back. Refused on the baseline, which holds the organisation's approved budget, for a line the plan doesn't " \
              "hold, and unless the caller is one of the plan's editors."
  category :write
  approval :mcp_client

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true, schema: { description: "The scenario. The baseline is refused." }
  parameter :budget_line_id, String, required: true, allow_blank: false

  # @return [Hash] `{ plan_id, scenario_id, budget_line_id }`
  def perform
    scenario_id = scenario!
    line_id = uuid!(:budget_line_id)
    set_change!(KIND, subject_id: line_id, end_state: { tenant_line: tenant_line?(line_id, line_changes(line_id).last) }) { |plan| held!(plan, line_id) }

    { plan_id: plan_id!, scenario_id:, budget_line_id: line_id }
  end
end
