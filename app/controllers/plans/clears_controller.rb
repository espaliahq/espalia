# frozen_string_literal: true

# Clears one change from a Changes tab row ([#424](https://github.com/espaliahq/espalia/issues/424)),
# through `team_planning_clear_change`, so the scenario follows its parent
# step there again.
class Plans::ClearsController < ApplicationController
  include Plans::MapEditing
  include Plans::TabReturn

  # POST /planning/:plan_id/clears
  def create
    authorize_editor
    Operations::TeamPlanning::ClearChange.call(context: pundit_user, params: { plan_id:, scenario_id:, subject_id: params.expect(:subject_id),
                                                                             facet: params.expect(:facet) })
    redirect_to back_to_tab, notice: "Change cleared. Undo brings it back.", status: :see_other
  rescue Operations::Base::ParameterError => e
    redirect_to back_to_tab, alert: "Couldn't clear the change: #{e.message}", status: :see_other
  end
end
