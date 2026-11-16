# frozen_string_literal: true

# The plan page's Redo button ([#424](https://github.com/espaliahq/espalia/issues/424)),
# through `team_planning_redo_change`. A refusal shows the operation's own words.
class Plans::RedosController < ApplicationController
  include Plans::MapEditing
  include Plans::TabReturn

  # POST /planning/:plan_id/redos
  def create
    authorize_editor
    Operations::TeamPlanning::RedoChange.call(context: pundit_user, params: { plan_id:, scenario_id:, event_id: params.expect(:event_id) })
    redirect_to back_to_tab, notice: "Change redone.", status: :see_other
  rescue Operations::Base::ParameterError => e
    redirect_to back_to_tab, alert: "Couldn't redo: #{e.message}", status: :see_other
  end
end
