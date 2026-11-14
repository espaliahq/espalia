# frozen_string_literal: true

# What the plan reads share: the plan they name, found only among the
# caller's own plans, so a plan they aren't in reads as an unknown id.
module Operations::TeamPlanning::PlanRead
  include Operations::TeamPlanning::PlanWrite

  private

  # @return [TeamPlanningPlan]
  # @raise [Operations::Base::ParameterError] "No such plan" unless the caller is a member
  def plan!
    plan = TeamPlanningPlan.includes(:members).find_by(id: plan_id!)
    return plan if plan && PlanPolicy.new(context, plan).show?

    raise Operations::Base::ParameterError, "No such plan"
  end
end
