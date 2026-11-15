# frozen_string_literal: true

# Writes, rewrites or clears the note on a planned change from the Changes tab
# ([#292](https://github.com/espaliahq/espalia/issues/292)), through the same
# Operation the MCP tool uses. A plan someone isn't in is a 404 here, as it is
# on the plan's page; a viewer is refused.
class Plans::NotesController < ApplicationController
  # PATCH /planning/:plan_id/notes/:id, the id being the change's event_id
  def update
    authorize_editor
    fields = params.expect(note: [ :scenario_id, :text ])
    noted = Operations::TeamPlanning::NoteChange.call(context: pundit_user, params: { plan_id:, scenario_id: fields[:scenario_id],
                                                                                    event_id: params.expect(:id), note: typed(fields[:text]) })
    redirect_back_or_to changes_plan_path(plan_id), notice: noted[:noted] ? "Note saved." : "Note cleared."
  rescue Operations::Base::ParameterError => e
    redirect_back_or_to changes_plan_path(plan_id), alert: "Couldn't save the note: #{e.message}"
  end

  private

  # A browser sends each line break as two characters, while the textarea's
  # maxlength counted it as one.
  def typed(text) = text&.gsub("\r\n", "\n")

  def plan_id = params.expect(:plan_id)

  # Reading the plan first makes one the caller isn't in a 404 rather than a
  # refusal, so the page never confirms it exists.
  def authorize_editor
    plan = Operations::TeamPlanning::Plan.call(context: pundit_user, params: { plan_id: })
    authorize TeamPlanningPlan.find(plan[:plan_id]), :update?, policy_class: PlanPolicy
  rescue Operations::Base::ParameterError => e
    raise ActiveRecord::RecordNotFound, e.message
  end
end
