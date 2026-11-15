# frozen_string_literal: true

# Gives the see-pay right back to a plan none of whose holders can still open
# it, for a tenant admin who never opens it. Without this, a plan whose holders
# had all gone could never show pay again.
class Operations::TeamPlanning::RestoreSeePay < Operations::Base
  include Operations::TeamPlanning::PlanWrite

  description "Restore a Team Planning plan locked out of pay, one where nobody who holds the see-pay right " \
              "can still open it, without opening it. Every editor who can still open the plan gets the " \
              "right, each grant recorded as yours. Refused, as an unknown plan, unless the plan is locked " \
              "out, still has such an editor, and the caller is a tenant admin."
  category :write
  approval :in_app

  parameter :plan_id, String, required: true

  # @return [Hash] `{ plan_id, restored }`, and nothing of the plan itself
  def perform
    plan_id = plan_id!
    refusing_bad_plans { handler.restore_see_pay(plan_id) }
    { plan_id: plan_id, restored: true }
  end
end
