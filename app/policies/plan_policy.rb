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
# Band ranges and actual pay need the see-pay right as well as membership,
# and only a holder passes it on. A plan none of whose holders can still
# open it is locked out of pay; a tenant admin may then give the right to its
# reachable editors, again without opening it.
#
# The record is a {TeamPlanning::PlanAggregate} or a {TeamPlanningPlan} row:
# anything with `role_of(person_id)`, `editor_ids`, `sees_pay?(person_id)`
# and `pay_holder_ids`.
#
# @example
#   PlanPolicy.new(context, plan).update?
class PlanPolicy < ApplicationPolicy
  # The plans the caller is a member of, and no others, whatever else they
  # are. {#show?} and this scope must agree; a policy test holds them together.
  class Scope
    # @param context [AuthorizationContext]
    # @param scope [ActiveRecord::Relation<TeamPlanningPlan>]
    def initialize(context, scope)
      @context = context
      @scope = scope
    end

    # @return [ActiveRecord::Relation<TeamPlanningPlan>]
    def resolve
      return @scope.none unless @context.tenant_user && PlanPolicy.reachable?(@context.person)

      @scope.where(id: TeamPlanningPlanMember.where(person_id: @context.person.id).select(:plan_id))
    end
  end

  # Whether the caller may work on plans at all; each plan then asks its own.
  # @return [Boolean]
  def index? = tenant_member?

  # @return [Boolean]
  def create? = tenant_member? && self.class.reachable?(person) && (tenant_admin? || context.team_planner?)

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

  # Whether the caller may see band ranges, and the actual pay the plan holds.
  # Every read of either asks this.
  # @return [Boolean]
  def see_pay? = role.present? && record.sees_pay?(person.id)

  # Whether the caller may give the see-pay right to a member, or take it.
  # The plan still refuses to lose its last holder.
  # @return [Boolean]
  def manage_see_pay? = see_pay?

  # Whether the caller may hold actual pay from a file
  # ([#323](https://github.com/espaliahq/espalia/issues/323)): an editor with the see-pay right.
  # @return [Boolean]
  def upload_pay? = editor? && see_pay?

  # Whether this plan is locked out of pay and the caller may restore it
  # unread. A frozen plan has no editor to restore it to.
  # @return [Boolean]
  def restore_see_pay? = manage_frozen? && self.class.locked_out?(record) && !self.class.frozen?(record)

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
  def self.frozen?(plan) = reachable_ids(plan.editor_ids).empty?

  # A plan is locked out of pay when none of those who hold the see-pay
  # right is still an active, unforgotten person with an account.
  #
  # @param plan [#pay_holder_ids]
  # @return [Boolean]
  def self.locked_out?(plan) = reachable_ids(plan.pay_holder_ids).empty?

  # Whether the caller can still be in a plan: active, and not forgotten.
  # Their tenant account is checked by `tenant_member?` beside each use.
  #
  # @param person [Person, nil]
  # @return [Boolean]
  def self.reachable?(person) = person.present? && person.status == "active" && !person.forgotten?

  # Those who can still open a plan: active, not forgotten, and holding an
  # account in this tenant. Someone without an account could join and never
  # get in, so they would keep a plan from freezing while nobody could edit it.
  #
  # @param person_ids [Array<String>]
  # @return [Set<String>]
  def self.reachable_ids(person_ids)
    Person.active.remembered.where(id: person_ids).where(id: TenantUser.select(:person_id)).pluck(:id).to_set
  end

  private

  def editor? = role == "editor"

  def role
    return @role if defined?(@role)

    @role = (record.role_of(person.id) if record && tenant_member? && self.class.reachable?(person))
  end
end
