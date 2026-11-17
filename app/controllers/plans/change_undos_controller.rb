# frozen_string_literal: true

# Undoes one named change from its Changes tab row, through
# `team_planning_undo_change`. The tab offers it beside Clear on a change about
# someone the plan no longer covers, where the plan page's Undo never reaches
# ([#435](https://github.com/espaliahq/espalia/issues/435)). The row names its
# own change, so unlike that Undo it can't act on one the page never showed.
class Plans::ChangeUndosController < ApplicationController
  include Plans::MapEditing
  include Plans::TabReturn

  # POST /planning/:plan_id/change-undos
  def create
    authorize_editor
    Operations::TeamPlanning::UndoChange.call(context: pundit_user, params: { plan_id:, scenario_id:, event_id: params.expect(:event_id) })
    redirect_to back_to_tab, notice: "Change undone.", status: :see_other
  rescue Operations::Base::ParameterError => e
    redirect_to back_to_tab, alert: "Couldn't undo: #{e.message}", status: :see_other
  end
end
