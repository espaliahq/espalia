# frozen_string_literal: true

# One plan the caller is in.
class Operations::TeamPlanning::Plan < Operations::Base
  include Operations::TeamPlanning::PlanRead

  description "Get one Team Planning plan the caller is a member of: its name, base date, the caller's role " \
              "in it (editor or viewer), and whether it is frozen, which means no editor can still reach it, " \
              "so its viewers read it and nobody changes it. Refused, as an unknown plan, unless the caller " \
              "is a member."
  category :read
  approval :none

  parameter :plan_id, String, required: true

  # @return [Hash] `{ plan_id, name, base_on, role, frozen }`
  def perform
    plan = plan!
    { plan_id: plan.id, name: plan.name, base_on: plan.base_on.iso8601, role: plan.role_of(context.person.id),
      frozen: PlanPolicy.frozen?(plan) }
  end
end
