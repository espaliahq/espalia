# frozen_string_literal: true

# The plans no editor can reach any more, for a tenant admin to delete. It
# says only that each exists, when it froze and how many viewers it has:
# never its name, contents or members.
class Operations::TeamPlanning::FrozenPlans < Operations::Base
  description "List the Team Planning plans that are frozen because none of their editors is still in the " \
              "organisation. Each is a plan id, the day it froze and its number of viewers; never its name, " \
              "contents or members. Tenant admins only, who may then delete one."
  category :read
  approval :none

  # @raise [Pundit::NotAuthorizedError] unless the caller is a tenant admin
  def policy_check
    authorize TeamPlanningPlan, :manage_frozen?, policy_class: PlanPolicy
  end

  # @return [Hash] `{ plans: [{ plan_id, frozen_on, viewer_count }] }`
  def perform
    plans = TeamPlanningPlan.includes(:members).to_a
    reachable = Person.active.remembered.where(id: plans.flat_map(&:editor_ids)).pluck(:id).to_set
    frozen = plans.select { |plan| plan.editor_ids.none? { reachable.include?(it) } }
    { plans: frozen.map { entry(it) }.sort_by { [ it[:frozen_on].to_s, it[:plan_id] ] } }
  end

  private

  def entry(plan)
    { plan_id: plan.id, frozen_on: frozen_on(plan.editor_ids)&.iso8601,
      viewer_count: plan.members.count { it.role == "viewer" } }
  end

  # The day its last editor left or was forgotten. PlanPolicy.frozen? is the
  # rule; this reads it for every plan at once.
  def frozen_on(editor_ids)
    left = OrgLeaver.where(person_id: editor_ids).pluck(:person_id, :left_on).to_h
    Person.where(id: editor_ids).map { left[it.id] || it.forgotten_at&.to_date || it.updated_at.to_date }.max
  end
end
