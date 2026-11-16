# frozen_string_literal: true

# A closed step's plan beside what happened
# ([#466](https://github.com/espaliahq/espalia/issues/466)), through
# `team_planning_step_outcome`, as the lazy frame in the step's outcome dialog.
# Any member may read it; anyone else gets a 404. A step that can't be read
# shows the operation's own words in the frame.
class Plans::StepOutcomesController < ApplicationController
  # GET /planning/:plan_id/scenarios/:scenario_id/outcome
  def show
    plan = Operations::TeamPlanning::Plan.call(context: pundit_user, params: { plan_id: params.expect(:plan_id) })
    authorize TeamPlanningPlan.find(plan[:plan_id]), :show?, policy_class: PlanPolicy
    return redirect_to plan_path(plan[:plan_id]) unless turbo_frame_request?

    render Views::Plans::StepOutcome.new(scenario_id:, **outcome(plan[:plan_id]))
  rescue Operations::Base::ParameterError => e
    raise ActiveRecord::RecordNotFound, e.message
  end

  private

  def scenario_id = params.expect(:scenario_id)

  def outcome(plan_id)
    { outcome: Operations::TeamPlanning::StepOutcome.call(context: pundit_user, params: { plan_id:, scenario_id: }) }
  rescue Operations::Base::ParameterError => e
    { refusal: e.message }
  end
end
