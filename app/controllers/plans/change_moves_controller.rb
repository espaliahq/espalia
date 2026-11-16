# frozen_string_literal: true

# Moves a place, a position or a departure a step earlier or later from the
# timeline ([#309](https://github.com/espaliahq/espalia/issues/309)), through
# the same Operation as the `team_planning_move_change` tool. A plan someone
# isn't in is a 404; a viewer is refused, and the plan refuses Today.
class Plans::ChangeMovesController < ApplicationController
  include Plans::MapEditing

  # POST /planning/:plan_id/change-moves
  def create
    authorize_editor
    result = Operations::TeamPlanning::MoveChange.call(context: pundit_user, params: { plan_id:, **move })
    redirect_to back_path || timeline_plan_path(plan_id), notice: "Moved to #{step_name(result[:to_scenario_id])}."
  rescue Operations::Base::ParameterError => e
    redirect_to back_path || timeline_plan_path(plan_id), alert: "Couldn't move it: #{e.message}"
  end

  private

  def move = params.expect(move: [ :scenario_id, :subject_id, :facet, :direction, :to_scenario_id ]).to_h.symbolize_keys.compact_blank

  def step_name(scenario_id) = TeamPlanningScenario.find_by(id: scenario_id)&.name&.reveal.presence || Views::Plans::Timeline::UNNAMED
end
