# frozen_string_literal: true

# Deletes a frozen plan, which no editor can reach, for a tenant admin who
# never opens it. Without this, a plan whose editors had all gone would hold
# its pay and notes for ever.
class Operations::TeamPlanning::DeleteFrozenPlan < Operations::Base
  include Operations::TeamPlanning::PlanWrite

  description "Delete a frozen Team Planning plan, one with no editor left in the organisation, without " \
              "opening it. It cannot be restored. Give the reason; it is kept with who deleted it. Refused, " \
              "as an unknown plan, unless the plan is frozen and the caller a tenant admin."
  category :destructive

  parameter :plan_id, String, required: true
  parameter :reason, String, required: true, allow_blank: false

  # @return [Hash] `{ plan_id, deleted }`, and nothing of the plan itself
  def perform
    plan_id = plan_id!
    refusing_bad_plans { handler.delete_frozen_plan(plan_id, reason: params[:reason]) }
    { plan_id: plan_id, deleted: true }
  end
end
