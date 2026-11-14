# frozen_string_literal: true

# Moves a person's place from the scenario map ([#285](https://github.com/espaliahq/espalia/issues/285)), through the same
# Operation as the `team_planning_move_place` tool. A plan someone isn't in is
# a 404, as on the plan's page; a viewer is refused, and so is Today.
class Plans::AssignmentsController < ApplicationController
  # PATCH /planning/:plan_id/assignments/:id
  def update
    authorize_editor
    Operations::TeamPlanning::MovePlace.call(context: pundit_user, params: { plan_id:, person_id: params.expect(:id), **move })
    redirect_to map_plan_path(plan_id, scenario: move[:scenario_id]), notice: "Move saved."
  rescue Operations::Base::ParameterError => e
    redirect_back_or_to map_plan_path(plan_id), alert: "Couldn't move them: #{e.message}"
  end

  private

  def plan_id = params.expect(:plan_id)

  # The form gives the allocation as a percentage.
  def move
    @move ||= begin
      fields = params.expect(move: [ :scenario_id, :from_unit_id, :from_position_id, :to_unit_id, :allocation, :role ])
      percent = fields[:allocation].presence
      { **fields.to_h.symbolize_keys.except(:allocation).compact_blank,
        allocation: (percent.to_f / 100 if percent && fields[:to_unit_id] != Operations::TeamPlanning::MovePlace::UNASSIGNED) }.compact
    end
  end

  # Reading the plan first makes one the caller isn't in a 404 rather than a
  # refusal, so the page never confirms it exists.
  def authorize_editor
    plan = Operations::TeamPlanning::Plan.call(context: pundit_user, params: { plan_id: })
    authorize TeamPlanningPlan.find(plan[:plan_id]), :update?, policy_class: PlanPolicy
  rescue Operations::Base::ParameterError => e
    raise ActiveRecord::RecordNotFound, e.message
  end
end
