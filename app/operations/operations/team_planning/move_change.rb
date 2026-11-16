# frozen_string_literal: true

# Moves a place, a position or a departure to the step before or after its
# own on the timeline ([#309](https://github.com/espaliahq/espalia/issues/309)).
# It moves no pay, so it asks for no right to see pay.
class Operations::TeamPlanning::MoveChange < Operations::Base
  include Operations::TeamPlanning::PlanWrite
  include Operations::TeamPlanning::WithinScope

  description "Move a change in a step of a Team Planning plan's timeline to the step before or after, so it " \
              "happens a step earlier or later. facet is assignment, position or departure; direction is earlier " \
              "or later. Every entry of that subject and facet goes across, so undo and redo work as before, and " \
              "team_planning_undo_change in the step it reached takes the whole move back. Moving earlier goes to " \
              "the step before on the path; moving later goes to the step after, and when more than one follows, " \
              "to_scenario_id names which. Refused when the step it would reach already changes that facet (the " \
              "refusal names that change), when either step is half of a split, when there is no step that way, " \
              "for a departure whose date falls outside the period of the step it would reach, or unless the " \
              "caller is an editor."
  category :write
  approval :mcp_client

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true
  parameter :subject_id, String, required: true, allow_blank: false
  parameter :facet, String, required: true, allow_blank: false, allowed: ::TeamPlanning::PlanAggregate::MOVABLE_FACETS
  parameter :direction, String, required: true, allow_blank: false, allowed: ::TeamPlanning::PlanAggregate::DIRECTIONS
  parameter :to_scenario_id, String

  # @return [Hash] `{ plan_id, scenario_id, to_scenario_id, subject_id, facet, moved }`
  def perform
    plan_id = plan_id!
    scenario_id = scenario_id!(:scenario_id)
    to_scenario_id = refusing_bad_plans do
      handler.move_change(plan_id, scenario_id:, subject_id: params[:subject_id], facet: params[:facet],
                                   direction: params[:direction], to_scenario_id: scenario_id!(:to_scenario_id)) do |plan, change, step_id|
        within_scope!(plan, change.class, change.data[:subject_id], change.data, scenario_id: step_id) if change
      end
    end
    { plan_id:, scenario_id:, to_scenario_id:, subject_id: params[:subject_id], facet: params[:facet], moved: true }
  end
end
