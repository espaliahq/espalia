# frozen_string_literal: true

# Takes back a change, pin or clear in a scenario
# [#243](https://github.com/espaliahq/espalia/issues/243).
class Operations::TeamPlanning::UndoChange < Operations::Base
  include Operations::TeamPlanning::PlanWrite
  include Operations::TeamPlanning::WithinScope

  description "Undo a change, pin or clear in a scenario of a Team Planning plan, so the scenario resolves as if " \
              "it had not been made. Give event_id, as team_planning_history lists it, or leave it out to undo " \
              "your own latest change in the scenario that can still be undone. Refused when a later change to " \
              "the same subject and facet replaced it (the refusal names that change: undo it first), when it is " \
              "already undone, or unless the caller is an editor. In a plan scoped to chosen units, an undo is " \
              "refused when the change it brings back is about someone, a unit or a position the plan no longer " \
              "covers, unless it places them in. Nothing is deleted: the history keeps it, marked undone."
  category :write
  approval :mcp_client

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true
  parameter :event_id, String

  # @return [Hash] `{ plan_id, scenario_id, event_id, undone }`
  def perform
    plan_id = plan_id!
    scenario_id = scenario_id!(:scenario_id)
    event_id = refusing_bad_plans do
      handler.undo_change(plan_id, scenario_id:, event_id: scenario_id!(:event_id)) do |plan, restored|
        within_scope!(plan, restored.class, restored.data[:subject_id], restored.data) if restored
      end
    end
    { plan_id:, scenario_id:, event_id:, undone: true }
  end
end
