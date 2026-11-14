# frozen_string_literal: true

# Moves a position to another unit from the scenario map
# ([#285](https://github.com/espaliahq/espalia/issues/285)), through the same
# Operation as the `team_planning_move_position` tool. A plan someone isn't in
# is a 404, as on the plan's page; a viewer is refused, and so is Today.
class Plans::PositionsController < ApplicationController
  include Plans::MapEditing

  # PATCH /planning/:plan_id/positions/:id
  def update
    authorize_editor
    Operations::TeamPlanning::MovePosition.call(context: pundit_user, params: { plan_id:, position_id: params.expect(:id), **move })
    redirect_to map_plan_path(plan_id, scenario: move[:scenario_id]), notice: "Position moved."
  rescue Operations::Base::ParameterError => e
    redirect_back_or_to map_plan_path(plan_id), alert: "Couldn't move the position: #{e.message}"
  end

  private

  def move = @move ||= params.expect(move: [ :scenario_id, :to_unit_id ]).to_h.symbolize_keys
end
