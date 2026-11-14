# frozen_string_literal: true

# Who may work on a Team Planning plan.
#
# A plan is private to its members. Viewers open it; editors also change it
# and choose its members. Being a tenant admin, an Org Graph editor or a
# planner opens no plan: only membership does. A member who leaves the
# organisation or is forgotten loses their plans at once.
#
# A tenant admin or a planner may create a plan. A plan with no editor left
# is frozen, and a tenant admin may then delete it without opening it.
#
# The record is a {TeamPlanning::PlanAggregate} or a {TeamPlanningPlan} row:
# anything with `role_of(person_id)` and `editor_ids`.
#
# @example
#   PlanPolicy.new(context, plan).update?
class PlanPolicy < ApplicationPolicy
  # Whether the caller may work on plans at all; each plan then asks its own.
  # @return [Boolean]
  def index? = tenant_member?

  # @return [Boolean]
  def create? = tenant_member? && (tenant_admin? || context.team_planner?)

  # @return [Boolean]
  def show? = role.present?

  # @return [Boolean]
  def update? = editor?

  # @return [Boolean]
  def destroy? = editor?

  # Whether the caller may add, remove or change the role of other members.
  # @return [Boolean]
  def manage_members? = editor?

  # Whether the caller may take themselves off the plan. The plan still
  # refuses its last editor.
  # @return [Boolean]
  def leave? = role.present?

  # Whether the caller may list the tenant's frozen plans, and delete one.
  # @return [Boolean]
  def manage_frozen? = tenant_member? && tenant_admin?

  # Whether this plan is frozen and the caller may delete it unread.
  # @return [Boolean]
  def destroy_frozen? = manage_frozen? && self.class.frozen?(record)

  # A plan is frozen when none of its editors is still an active,
  # unforgotten person.
  #
  # @param plan [#editor_ids]
  # @return [Boolean]
  def self.frozen?(plan) = Person.active.remembered.where(id: plan.editor_ids).none?

  private

  def editor? = role == "editor"

  def role
    return @role if defined?(@role)

    @role = (record.role_of(context.person.id) if record && tenant_member? && reachable_person?)
  end

  def reachable_person?
    person = context.person
    person.present? && person.status == "active" && !person.forgotten?
  end
end
