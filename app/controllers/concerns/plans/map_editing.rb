# frozen_string_literal: true

# What the scenario map's edit controllers share
# ([#285](https://github.com/espaliahq/espalia/issues/285)): the plan from the
# route, the editor check, and the timeline to return to.
module Plans::MapEditing
  extend ActiveSupport::Concern

  private

  def plan_id = params.expect(:plan_id)

  # Only this plan's timeline, so the field can't send someone off the page.
  def back_path
    uri = URI.parse(params[:return_to].to_s)
    params[:return_to] if uri.host.nil? && uri.scheme.nil? && uri.path == timeline_plan_path(plan_id)
  rescue URI::InvalidURIError
    nil
  end

  # Reading the plan first makes one the caller isn't in a 404 rather than a
  # refusal, so the page never confirms it exists.
  def authorize_editor
    plan = Operations::TeamPlanning::Plan.call(context: pundit_user, params: { plan_id: })
    authorize TeamPlanningPlan.find(plan[:plan_id]), :update?, policy_class: PlanPolicy
  rescue Operations::Base::ParameterError => e
    raise ActiveRecord::RecordNotFound, e.message
  end
end
