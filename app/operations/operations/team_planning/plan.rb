# frozen_string_literal: true

# One plan the caller is in.
class Operations::TeamPlanning::Plan < Operations::Base
  include Operations::TeamPlanning::PlanRead

  description "Get one Team Planning plan the caller is a member of: its name, base date, the caller's role " \
              "in it (editor or viewer), the units it covers (scope: the whole organisation, or chosen units, each with " \
              "everything under it), and whether it is frozen, which means no editor can still reach it, " \
              "so its viewers read it and nobody changes it. Refused, as an unknown plan, unless the caller " \
              "is a member."
  category :read
  approval :none

  parameter :plan_id, String, required: true

  # @return [Hash] `{ plan_id, name, base_on, role, scope, frozen }`
  def perform
    plan = plan!
    { plan_id: plan.id, name: plan.name&.reveal, base_on: plan.base_on.iso8601, role: plan.role_of(context.person.id),
      scope: self.class.scope_of(plan), frozen: PlanPolicy.frozen?(plan) }
  end

  # @param plan [TeamPlanningPlan]
  # @return [Hash] `{ whole_organisation, units: [{ unit_id, name }] }`
  def self.scope_of(plan)
    ids = plan.scope_unit_ids.to_a
    names = OrgUnit.where(id: ids).pluck(:id, :name).to_h
    { whole_organisation: ids.empty?, units: ids.map { { unit_id: it, name: names[it] } } }
  end
end
