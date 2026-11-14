# frozen_string_literal: true

# Grants and withdraws the see-pay right from the plan's members panel
# ([#300](https://github.com/espaliahq/espalia/issues/300)), through the same
# Operations as the MCP tools. A plan someone isn't in is a 404, as on the
# plan's page; a member without the right is refused.
class Plans::SeePayController < ApplicationController
  # PATCH /planning/:plan_id/see_pay/:id
  def update
    change(Operations::TeamPlanning::GrantSeePay, done: "can now see pay", failed: "Couldn't give them the right")
  end

  # DELETE /planning/:plan_id/see_pay/:id
  def destroy
    change(Operations::TeamPlanning::WithdrawSeePay, done: "can no longer see pay", failed: "Couldn't withdraw the right")
  end

  private

  def change(operation, done:, failed:)
    authorize_holder
    operation.call(context: pundit_user, params: { plan_id:, person_id: })
    redirect_to plan_path(plan_id), notice: "#{Person.find_by(id: person_id)&.name || 'They'} #{done}."
  rescue Operations::Base::ParameterError => e
    redirect_back_or_to plan_path(plan_id), alert: "#{failed}: #{e.message}"
  end

  def plan_id = params.expect(:plan_id)

  def person_id = params.expect(:id)

  # Reading the plan first makes one the caller isn't in a 404 rather than a
  # refusal, so the page never confirms it exists.
  def authorize_holder
    plan = Operations::TeamPlanning::Plan.call(context: pundit_user, params: { plan_id: })
    authorize TeamPlanningPlan.find(plan[:plan_id]), :manage_see_pay?, policy_class: PlanPolicy
  rescue Operations::Base::ParameterError => e
    raise ActiveRecord::RecordNotFound, e.message
  end
end
