# frozen_string_literal: true

# Takes the see-pay right from a plan member, or lets a holder give it up.
#
# Approval is :in_app, as it changes who can read pay.
class Operations::TeamPlanning::WithdrawSeePay < Operations::Base
  include Operations::TeamPlanning::PlanWrite

  description "Take the see-pay right from a member of a Team Planning plan, or give up your own. A plan " \
              "keeps one holder who can still open it. Refused, as an unknown plan, unless the caller holds " \
              "the right."
  category :write
  approval :in_app

  parameter :plan_id, String, required: true
  parameter :person_id, String, required: true, allow_blank: false

  # @return [Hash] `{ plan_id, person_id, see_pay }`
  def perform
    plan_id = plan_id!
    person_id = params[:person_id].to_s.downcase
    plan = refusing_bad_plans { handler.withdraw_see_pay(plan_id, person_id) }
    { plan_id: plan_id, person_id: person_id, see_pay: plan.sees_pay?(person_id) }
  end
end
