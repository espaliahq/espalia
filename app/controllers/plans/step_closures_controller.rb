# frozen_string_literal: true

# Closes a step from the plan page or the timeline, and reopens the last one
# closed ([#466](https://github.com/espaliahq/espalia/issues/466)), through
# `team_planning_close_step` and `team_planning_reopen_step`. A refusal shows
# the operation's own words.
class Plans::StepClosuresController < ApplicationController
  include Plans::MapEditing

  # POST /planning/:plan_id/scenarios/:scenario_id/closure
  def create
    authorize_editor
    Operations::TeamPlanning::CloseStep.call(context: pundit_user, params: { plan_id:, scenario_id: })
    redirect_to back, status: :see_other, notice: "Closed #{name}. The steps after it now start from the organisation as it stood the day after."
  rescue Operations::Base::ParameterError => e
    redirect_to back, status: :see_other, alert: "Couldn't close #{name}: #{e.message}"
  end

  # DELETE /planning/:plan_id/scenarios/:scenario_id/closure
  def destroy
    authorize_editor
    Operations::TeamPlanning::ReopenStep.call(context: pundit_user, params: { plan_id:, scenario_id: })
    redirect_to back, status: :see_other, notice: "Reopened #{name}."
  rescue Operations::Base::ParameterError => e
    redirect_to back, status: :see_other, alert: "Couldn't reopen #{name}: #{e.message}"
  end

  private

  def scenario_id = params.expect(:scenario_id)

  def back = back_path || plan_path(plan_id)

  def name
    @name ||= TeamPlanningScenario.find_by(id: scenario_id.downcase, plan_id:)&.name&.reveal || "the step"
  end
end
