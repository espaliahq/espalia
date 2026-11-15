# frozen_string_literal: true

# What the plan reads share: the plan they name, found only among the
# caller's own plans, so a plan they aren't in reads as an unknown id.
#
# A plan keeps one editor who is still in the organisation
# [#203](https://github.com/espaliahq/espalia/issues/203). Being a tenant
# admin, a planner or an Org Graph editor opens no plan:
# test/integration/team_planning_privacy_test.rb walks every tool to hold
# that.
module Operations::TeamPlanning::PlanRead
  include Operations::TeamPlanning::PlanWrite

  private

  # @param may [Symbol] the {PlanPolicy} question, `:update?` for a write that checks before its handler does
  # @return [TeamPlanningPlan]
  # @raise [Operations::Base::ParameterError] "No such plan" unless the caller is a member, or may do what `may` asks
  def plan!(may = :show?)
    plan = TeamPlanningPlan.includes(:members).find_by(id: plan_id!)
    return plan if plan && PlanPolicy.new(context, plan).public_send(may)

    raise Operations::Base::ParameterError, "No such plan"
  end
end
