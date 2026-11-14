# frozen_string_literal: true

# The plans the caller is a member of, with their role in each.
class Operations::TeamPlanning::Plans < Operations::Base
  include Operations::TeamPlanning::PlanWrite

  description "List the Team Planning plans the caller is a member of, with each one's name, base date and " \
              "the caller's role in it (editor or viewer). Being a tenant admin or a planner adds no plans."
  category :read
  approval :none

  # @return [Hash] `{ plans: [{ plan_id, name, base_on, role }] }`; a removed name is nil
  def perform
    plans = PlanPolicy::Scope.new(context, TeamPlanningPlan).resolve.includes(:members).map do
      { plan_id: it.id, name: it.name&.reveal, base_on: it.base_on.iso8601, role: it.role_of(context.person.id) }
    end
    # A name is sealed, so the caller's own few plans sort here, not in SQL.
    { plans: plans.sort_by { [ it[:name].to_s, it[:plan_id] ] } }
  end
end
