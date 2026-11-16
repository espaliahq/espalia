# frozen_string_literal: true

# Hands one facet of one subject back to a scenario's parent. Reconcile (4.5)
# calls it to follow reality
# [#239](https://github.com/espaliahq/espalia/issues/239).
class Operations::TeamPlanning::ClearChange < Operations::Base
  include Operations::TeamPlanning::PlanWrite
  include Operations::TeamPlanning::WithinScope

  description "Stop a scenario of a Team Planning plan overriding one facet of one subject, so it follows its " \
              "parent there again: the 'follow reality' answer when reconciling. facet is as " \
              "team_planning_overrides lists it, such as 'rule:<name>'. The earlier change stays in the plan's history. Refused if the scenario doesn't change that facet, or " \
              "unless the caller is an editor. Without the see-pay right, a budget line that carries an amount is refused too."
  category :write
  approval :mcp_client

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true
  parameter :subject_id, String, required: true, allow_blank: false
  parameter :facet, String, required: true, allow_blank: false

  # @return [Hash] `{ plan_id, scenario_id, subject_id, facet, cleared }`
  def perform
    plan_id = plan_id!
    scenario_id = scenario_id!(:scenario_id)
    refusing_bad_plans do
      handler.clear_change(plan_id, scenario_id:, subject_id: params[:subject_id], facet: params[:facet]) do |plan|
        plan.nothing_to_clear!(scenario_id) if hidden_line?(plan, scenario_id)
      end
    end
    { plan_id:, scenario_id:, subject_id: params[:subject_id], facet: params[:facet], cleared: true }
  end

  private

  # A budget line outside a scoped plan's cost centres reads as one with no
  # change to clear ([#378](https://github.com/espaliahq/espalia/issues/378)),
  # before any other refusal can tell it apart.
  def hidden_line?(plan, scenario_id)
    return false unless params[:facet] == ::TeamPlanning::Events::BudgetLineSet.facet

    record = TeamPlanningPlan.find(plan.plan_id)
    return false if record.scope_unit_ids.blank?

    map, = ::TeamPlanning::Resolution.new(context:, plan: record, scenario_id:).resolved(plan)
    line_outside?(plan, map, scenario_id, params[:subject_id])
  end
end
