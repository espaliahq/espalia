# frozen_string_literal: true

# Restores an undone change, pin or clear in a scenario
# [#243](https://github.com/espaliahq/espalia/issues/243).
class Operations::TeamPlanning::RedoChange < Operations::Base
  include Operations::TeamPlanning::PlanWrite
  include Operations::TeamPlanning::WithinScope

  description "Redo a change, pin or clear that was undone in a scenario of a Team Planning plan, in its place. " \
              "Give event_id, as team_planning_history lists it, or leave it out to redo what your own latest " \
              "undo in the scenario took back. In a plan scoped to chosen units, a change about someone, a unit or a " \
              "position it no longer covers is refused unless it places them in one of its units. Refused when a " \
              "change to the same subject and facet was made since (the refusal names it), when it isn't undone, " \
              "when it brings back a last day outside the dates of the step they leave in, or unless the caller " \
              "is an editor."
  category :write
  approval :mcp_client

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true
  parameter :event_id, String

  # @return [Hash] `{ plan_id, scenario_id, event_id, redone }`
  def perform
    plan_id = plan_id!
    scenario_id = scenario_id!(:scenario_id)
    event_id = refusing_bad_plans do
      handler.redo_change(plan_id, scenario_id:, event_id: scenario_id!(:event_id)) do |plan, entry|
        within_scope!(plan, entry.class, entry.data[:subject_id], entry.data) if entry.is_a?(::TeamPlanning::Events::Change)
      end
    end
    { plan_id:, scenario_id:, event_id:, redone: true }
  end
end
