# frozen_string_literal: true

# Moves a person's place from the scenario map ([#285](https://github.com/espaliahq/espalia/issues/285)) or the timeline
# ([#309](https://github.com/espaliahq/espalia/issues/309)), through the same
# Operation as the `team_planning_move_place` tool. A plan someone isn't in is
# a 404, as on the plan's page; a viewer is refused, and so is Today.
class Plans::AssignmentsController < ApplicationController
  include Plans::MapEditing

  # PATCH /planning/:plan_id/assignments/:id
  def update
    authorize_editor
    Operations::TeamPlanning::MovePlace.call(context: pundit_user, params: { plan_id:, person_id: params.expect(:id), **move })
    redirect_to back_path || map_plan_path(plan_id, scenario: move[:scenario_id]), notice: "Move saved."
  rescue Operations::Base::ParameterError => e
    alert = "Couldn't move them: #{e.message}"
    back_path ? redirect_to(back_path, alert:) : redirect_back_or_to(map_plan_path(plan_id), alert:)
  end

  private

  # Only this plan's timeline, so the field can't send someone off the page.
  def back_path
    uri = URI.parse(params[:return_to].to_s)
    params[:return_to] if uri.host.nil? && uri.scheme.nil? && uri.path == timeline_plan_path(plan_id)
  rescue URI::InvalidURIError
    nil
  end

  # The form gives the allocation as a percentage, and its destination as a
  # unit, "unassigned", or a position as {Views::Plans::MoveDialog.position_choice}.
  def move
    @move ||= begin
      fields = params.expect(move: [ :scenario_id, :from_unit_id, :from_position_id, :to, :allocation, :role ])
      percent = fields[:allocation].presence
      leaving = fields[:to] == Operations::TeamPlanning::MovePlace::UNASSIGNED
      { **fields.to_h.symbolize_keys.except(:allocation, :to).compact_blank, **destination(fields[:to].to_s),
        allocation: (percent.to_f / 100 if percent && !leaving) }.compact
    end
  end

  def destination(to)
    position = to.delete_prefix(Views::Plans::MoveDialog::POSITION)
    position == to ? { to_unit_id: to } : { to_position_id: position }
  end
end
