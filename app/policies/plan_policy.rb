# frozen_string_literal: true

# Who may work on a Team Planning plan.
#
# A plan is private to its creator: a tenant admin does not open someone
# else's plan. Until story 1.2 adds members and the planner role, only a
# tenant admin may create one.
#
# The record is anything with a `created_by_id`: a {TeamPlanning::PlanAggregate}
# or a {TeamPlanningPlan} row.
#
# @example
#   PlanPolicy.new(context, plan).update?
class PlanPolicy < ApplicationPolicy
  # @return [Boolean]
  def create? = tenant_admin?

  # @return [Boolean]
  def show? = creator?

  # @return [Boolean]
  def update? = creator?

  # @return [Boolean]
  def destroy? = creator?

  private

  def creator?
    tenant_member? && context.person.present? && record&.created_by_id == context.person.id
  end
end
