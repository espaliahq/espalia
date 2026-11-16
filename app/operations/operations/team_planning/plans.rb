# frozen_string_literal: true

# The plans the caller is a member of, with their role in each.
class Operations::TeamPlanning::Plans < Operations::Base
  include Operations::TeamPlanning::PlanWrite

  description "List the Team Planning plans the caller is a member of, with each one's name, base date and " \
              "the caller's role in it (editor or viewer), and archived_on, the day it was archived, or null for a live plan. " \
              "state picks which: live (the default), archived or all. Being a tenant admin or a planner adds no plans."
  category :read
  approval :none

  STATES = %w[live archived all].freeze

  parameter :state, String, schema: { enum: STATES, description: "Which plans: live (the default), archived or all." }

  # @return [Hash] `{ plans: [{ plan_id, name, base_on, role, archived_on }] }`; a removed name is nil
  def perform
    plans = in_state(PlanPolicy::Scope.new(context, TeamPlanningPlan).resolve).includes(:members).map do
      { plan_id: it.id, name: it.name&.reveal, base_on: it.base_on.iso8601, role: it.role_of(context.person.id),
        archived_on: it.archived_on&.iso8601 }
    end
    # A name is sealed, so the caller's own few plans sort here, not in SQL.
    # Case aside, as the database collation sorted them, with removed names last.
    { plans: plans.sort_by { [ it[:name] ? 0 : 1, it[:name].to_s.unicode_normalize(:nfkc).downcase, it[:plan_id] ] } }
  end

  private

  def in_state(plans)
    case params[:state] || "live"
    when "live" then plans.live
    when "archived" then plans.archived
    when "all" then plans
    else raise Operations::Base::ParameterError, "state must be one of #{STATES.join(', ')}"
    end
  end
end
