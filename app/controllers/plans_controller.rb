# frozen_string_literal: true

# Team Planning's plans index and plan page (#226). Every read goes through
# the Team Planning Operations, as the MCP tools do, so a plan someone isn't
# in is a 404 here and "No such plan" there.
class PlansController < ApplicationController
  # GET /planning
  def index
    authorize TeamPlanningPlan, :index?, policy_class: PlanPolicy
    render index_view
  end

  # POST /planning
  def create
    authorize TeamPlanningPlan, :create?, policy_class: PlanPolicy
    draft = params.expect(plan: [ :name, :base_on ]).to_h.symbolize_keys
    plan = Operations::TeamPlanning::CreatePlan.call(context: pundit_user, params: draft)
    redirect_to plan_path(plan[:plan_id]), notice: "Plan created."
  rescue Operations::Base::ParameterError => e
    render index_view(error: e.message, draft:), status: :unprocessable_content
  end

  # GET /planning/:id
  def show
    plan = read(Operations::TeamPlanning::Plan)
    authorize TeamPlanningPlan.find(plan[:plan_id]), :show?, policy_class: PlanPolicy
    render Views::Plans::ShowView.new(
      plan:,
      scenarios: read(Operations::TeamPlanning::Scenarios)[:scenarios],
      members: read(Operations::TeamPlanning::PlanMembers)[:members],
      **layout
    )
  end

  private

  def index_view(error: nil, draft: {})
    Views::Plans::IndexView.new(
      plans: Operations::TeamPlanning::Plans.call(context: pundit_user)[:plans],
      can_create: policy_for(TeamPlanningPlan).create?,
      error:,
      draft:,
      **layout
    )
  end

  # The Operations decide who may open a plan, so their "No such plan" is
  # this page's 404, as it is the MCP tools' refusal.
  def read(operation)
    operation.call(context: pundit_user, params: { plan_id: params.expect(:id) })
  rescue Operations::Base::ParameterError => e
    raise ActiveRecord::RecordNotFound, e.message
  end

  def policy_for(record) = PlanPolicy.new(pundit_user, record)

  def layout
    { user: current_user, current_tenant: ActsAsTenant.current_tenant,
      tenants: ActsAsTenant.without_tenant { current_user.tenants.to_a } }
  end
end
