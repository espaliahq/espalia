# frozen_string_literal: true

# Who is in a plan, and as what. Ids only until story 1.4 brings names.
class Operations::TeamPlanning::PlanMembers < Operations::Base
  include Operations::TeamPlanning::PlanRead

  description "List the members of a Team Planning plan the caller is in, each a person id and a role " \
              "(editor or viewer). Refused, as an unknown plan, unless the caller is a member."
  category :read
  approval :none

  parameter :plan_id, String, required: true

  # @return [Hash] `{ plan_id, members: [{ person_id, role }] }`
  def perform
    plan = plan!
    members = plan.members.sort_by { [ it.role, it.person_id ] }.map { { person_id: it.person_id, role: it.role } }
    { plan_id: plan.id, members: members }
  end
end
