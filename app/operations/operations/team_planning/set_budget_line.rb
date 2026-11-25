# frozen_string_literal: true

# Changes a budget line in a scenario, or adds one the organisation hasn't
# approved, as a BudgetLineSet change
# [#302](https://github.com/espaliahq/espalia/issues/302). The amount seals
# under the plan's key, so deleting the plan shreds it. A changed tenant line
# keeps its id; an added line gets one the plan mints.
#
# If the organisation later removes a line this changes, the change stays and
# reads as orphaned, so team_planning_attention flags it.
class Operations::TeamPlanning::SetBudgetLine < Operations::Base
  include Operations::TeamPlanning::BudgetLineWrite
  include Operations::Tenants::BudgetLineFields

  KIND = ::TeamPlanning::Events::BudgetLineSet

  description "Change a budget line in a scenario of a Team Planning plan, or add one. Give budget_line_id from " \
              "team_planning_budget_lines to change a line the scenario holds, or leave it out to add one. Give every " \
              "field as the line reads afterwards: a field left out is cleared. The change reaches the scenarios that " \
              "follow, and a later change by the organisation to the same line no longer does. " \
              "#{Operations::Tenants::BudgetLineFields::HELP} Refused on the baseline, which holds the organisation's " \
              "approved budget, in a plan that covers some units for a line whose cost centre none of its seats can draw on, " \
              "and unless the caller is one of the plan's editors. A budget amount is pay: without the see-pay right, " \
              "amount, currency and period are refused, and so is a change to a line that carries an amount."
  category :write
  approval :mcp_client

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true, schema: { description: "The scenario. The baseline is refused." }
  parameter :budget_line_id, String, allow_blank: false, schema: { description: "Omit to add a line." }
  Operations::Tenants::BudgetLineFields.line_parameters(self)

  # @return [Hash] `{ plan_id, scenario_id, budget_line_id, source }`
  def perform
    scenario_id = scenario!
    line_id = params[:budget_line_id].nil? ? SecureRandom.uuid_v7 : uuid!(:budget_line_id)
    changes = params[:budget_line_id].nil? ? [] : line_changes(line_id)
    held!(loaded_plan, line_id) unless params[:budget_line_id].nil?
    line_money!(loaded_plan, line_id) unless params[:budget_line_id].nil?
    no_money_given!
    tenant_line = !params[:budget_line_id].nil? && tenant_line?(line_id, changes.last)
    line = assign_line(held_line(line_id, changes))
    set_change!(KIND, subject_id: line_id, end_state: figures(line).merge(tenant_line:)) do |plan|
      unless params[:budget_line_id].nil?
        held!(plan, line_id)
        line_money!(plan, line_id)
      end
    end

    { plan_id: plan_id!, scenario_id:, budget_line_id: line_id, source: tenant_line ? "changed" : "plan" }
  end

  private

  # The line's role and level as the scenario last set them, even before a cut, or as the organisation holds
  # them, so a role or level gone from the framework may be given again.
  def held_line(line_id, changes)
    kept = changes.reverse.find { it.is_a?(KIND) }&.data || TenantPlanningInputs::Projections::Tables.unless_rebuilding { ::BudgetLine.find_by(id: line_id) }&.attributes.to_h.symbolize_keys
    ::BudgetLine.new(kept.to_h.slice(:role_id, :level_id, :role_name, :level_name))
  end

  def figures(line) = line.attributes.symbolize_keys.slice(*::TeamPlanning::Baseline::BUDGET_FIGURES)
end
