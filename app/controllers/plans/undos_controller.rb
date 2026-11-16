# frozen_string_literal: true

# The plan page's Undo button ([#424](https://github.com/espaliahq/espalia/issues/424)),
# through `team_planning_undo_change`. A refusal shows the operation's own words.
class Plans::UndosController < ApplicationController
  include Plans::MapEditing
  include Plans::TabReturn

  # POST /planning/:plan_id/undos
  def create
    authorize_editor
    Operations::TeamPlanning::UndoChange.call(context: pundit_user, params: { plan_id:, scenario_id:, event_id: params.expect(:event_id) })
    redirect_to back_to_tab, notice: "Change undone.", status: :see_other
  rescue Operations::Base::ParameterError => e
    redirect_to back_to_tab, alert: "Couldn't undo: #{e.message}", status: :see_other
  end
end
