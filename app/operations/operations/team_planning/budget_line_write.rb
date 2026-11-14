# frozen_string_literal: true

# What the tools that set or cut a scenario's budget line share. The
# baseline holds the organisation's approved budget as it is, so only a
# scenario changes it.
module Operations::TeamPlanning::BudgetLineWrite
  extend ActiveSupport::Concern
  include Operations::TeamPlanning::ChangeWrite

  BASELINE = "The baseline holds the organisation's approved budget as it is: change a line in a scenario"
  FACET = ::TeamPlanning::Events::BudgetLineSet.facet

  private

  # The handler checks again under the lock; this keeps every other refusal behind it.
  def editable_plan!
    plan = ::TeamPlanningPlan.find_by(id: plan_id!)
    return plan if plan && PlanPolicy.new(context, plan).update?

    raise Operations::Base::ParameterError, "No such plan"
  end

  def scenario!
    editable_plan!
    scenario_id = scenario_id!(:scenario_id)
    raise Operations::Base::ParameterError, BASELINE if scenario_id == plan_id!

    scenario_id
  end

  # @return [Boolean] whether the id names one of the organisation's lines
  def tenant_line?(line_id) = ::BudgetLine.exists?(id: line_id)

  # Refuses a line the scenario doesn't hold: neither the organisation's nor one this plan set along its chain.
  def held!(plan, line_id)
    return if tenant_line?(line_id) || winning_change(plan, line_id, FACET).is_a?(::TeamPlanning::Events::BudgetLineSet)

    raise Operations::Base::ParameterError, "This scenario has no such budget line"
  end
end
