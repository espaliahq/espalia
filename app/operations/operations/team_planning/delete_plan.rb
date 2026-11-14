# frozen_string_literal: true

# Deletes a plan. Only its creator may, and a deleted plan stays deleted.
class Operations::TeamPlanning::DeletePlan < Operations::Base
  include Operations::TeamPlanning::PlanWrite

  description "Delete a Team Planning plan. It cannot be restored. Refused unless the caller created the plan."
  category :destructive

  parameter :plan_id, String, required: true

  # @return [Hash] `{ plan_id, deleted }`
  def perform
    plan_id = plan_id!
    refusing_bad_plans { handler.delete_plan(plan_id) }
    { plan_id: plan_id, deleted: true }
  end
end
