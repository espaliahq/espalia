# frozen_string_literal: true

# Makes someone a member of a plan, or changes their role. Only an editor may.
#
# Approval is :in_app, as it lets someone read a plan's pay and notes.
class Operations::TeamPlanning::AddPlanMember < Operations::Base
  include Operations::TeamPlanning::PlanWrite

  description "Make an active person a member of a Team Planning plan as an editor or a viewer, or change " \
              "a member's role. A plan keeps at least one editor. Refused, as an unknown plan, unless the " \
              "caller is one of its editors."
  category :write
  approval :in_app

  parameter :plan_id, String, required: true
  parameter :person_id, String, required: true, allow_blank: false
  parameter :role, String, required: true, schema: { enum: TeamPlanning::PlanAggregate::ROLES }

  # @return [Hash] `{ plan_id, person_id, role }`
  def perform
    plan_id = plan_id!
    person_id = params[:person_id].to_s.downcase
    plan = refusing_bad_plans { handler.add_member(plan_id, person_id, role: params[:role]) }
    { plan_id: plan_id, person_id: person_id, role: plan.role_of(person_id) }
  end
end
