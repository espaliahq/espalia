# frozen_string_literal: true

# Takes someone off a plan. An editor may take anyone off; any member may
# take themselves off.
#
# Approval is :in_app, as it changes who can read the plan.
class Operations::TeamPlanning::RemovePlanMember < Operations::Base
  include Operations::TeamPlanning::PlanWrite

  description "Take a member off a Team Planning plan. An editor may remove anyone, and any member may " \
              "remove themselves, except its last editor. Refused, as an unknown plan, unless the caller " \
              "may."
  category :write
  approval :in_app

  parameter :plan_id, String, required: true
  parameter :person_id, String, required: true, allow_blank: false

  # @return [Hash] `{ plan_id, person_id, removed }`
  def perform
    plan_id = plan_id!
    person_id = params[:person_id].to_s.downcase
    refusing_bad_plans { handler.remove_member(plan_id, person_id) }
    { plan_id: plan_id, person_id: person_id, removed: true }
  end
end
