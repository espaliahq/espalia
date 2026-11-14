# frozen_string_literal: true

# The plans the caller is a member of, with their role in each.
class Operations::TeamPlanning::Plans < Operations::Base
  include Operations::TeamPlanning::PlanWrite

  description "List the Team Planning plans the caller is a member of, with each one's name, base date and " \
              "the caller's role in it (editor or viewer). Being a tenant admin or a planner adds no plans."
  category :read
  approval :none

  # @return [Hash] `{ plans: [{ plan_id, name, base_on, role }] }`
  def perform
    plans = PlanPolicy::Scope.new(context, TeamPlanningPlan).resolve.includes(:members).order(:name, :id)
    { plans: plans.map { { plan_id: it.id, name: it.name, base_on: it.base_on.iso8601, role: it.role_of(context.person.id) } } }
  end
end
