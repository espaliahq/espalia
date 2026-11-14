# frozen_string_literal: true

# The plans no editor can reach any more, for a tenant admin to delete. It
# says only that each exists, when it froze and how many viewers it has:
# never its name, contents or members.
class Operations::TeamPlanning::FrozenPlans < Operations::Base
  description "List the Team Planning plans that are frozen because none of their editors is still in the " \
              "organisation. Each is a plan id, the day it froze (null when no leaving date is known) and the " \
              "number of viewers who can still read it; never its name, contents or members. Tenant admins " \
              "only, who may then delete one."
  category :read
  approval :none

  # @raise [Pundit::NotAuthorizedError] unless the caller is a tenant admin
  def policy_check
    authorize TeamPlanningPlan, :manage_frozen?, policy_class: PlanPolicy
  end

  # @return [Hash] `{ plans: [{ plan_id, frozen_on, viewer_count }] }`; frozen_on is
  #   nil when no leaving date is known for its editors
  def perform
    plans = TeamPlanningPlan.includes(:members).to_a
    reachable = PlanPolicy.reachable_ids(plans.flat_map(&:members).map(&:person_id))
    # A plan always has an editor, so one with no editor rows is a projection
    # that hasn't caught up, not a frozen plan the delete would accept.
    frozen = plans.select { |plan| plan.editor_ids.any? && plan.editor_ids.none? { reachable.include?(it) } }
    gone_on = gone_on(frozen.flat_map(&:editor_ids))

    entries = frozen.map do |plan|
      { plan_id: plan.id, frozen_on: plan.editor_ids.filter_map { gone_on[it] }.max&.iso8601,
        viewer_count: plan.members.count { it.role == "viewer" && reachable.include?(it.person_id) } }
    end
    { plans: entries.sort_by { [ it[:frozen_on].to_s, it[:plan_id] ] } }
  end

  private

  # The day each person left or was forgotten, where the Org Graph knows it.
  # PlanPolicy.frozen? is the rule; this reads it for every plan at once.
  def gone_on(person_ids)
    left = OrgLeaver.where(person_id: person_ids).pluck(:person_id, :left_on).to_h
    forgotten = Person.forgotten.where(id: person_ids).pluck(:id, :forgotten_at).to_h { |id, at| [ id, at.to_date ] }
    forgotten.merge(left)
  end
end
