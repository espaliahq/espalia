# frozen_string_literal: true

# Lets a plan member see band ranges, and the actual pay the plan holds.
#
# Approval is :in_app, as it lets someone read pay.
class Operations::TeamPlanning::GrantSeePay < Operations::Base
  include Operations::TeamPlanning::PlanWrite

  description "Give a member of a Team Planning plan the see-pay right: band ranges, and any actual pay the " \
              "plan holds. Without it a member sees band midpoints only. Refused, as an unknown plan, unless " \
              "the caller holds the right."
  category :write
  approval :in_app

  parameter :plan_id, String, required: true
  parameter :person_id, String, required: true, allow_blank: false

  # @return [Hash] `{ plan_id, person_id, see_pay }`
  def perform
    plan_id = plan_id!
    person_id = params[:person_id].to_s.downcase
    plan = refusing_bad_plans { handler.grant_see_pay(plan_id, person_id) }
    { plan_id: plan_id, person_id: person_id, see_pay: plan.sees_pay?(person_id) }
  end
end
