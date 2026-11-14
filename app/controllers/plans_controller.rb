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
    plan = Operations::TeamPlanning::CreatePlan.call(context: pundit_user, params: params.expect(plan: [ :name, :base_on ]).to_h)
    redirect_to plan_path(plan[:plan_id]), notice: "Plan created."
  rescue Operations::Base::ParameterError => e
    render index_view(error: e.message), status: :unprocessable_content
  end

  # GET /planning/:id
  def show
    plan = TeamPlanningPlan.includes(:members).find_by(id: params.expect(:id))
    raise ActiveRecord::RecordNotFound, "No such plan" unless plan && policy_for(plan).show?

    authorize plan, :show?, policy_class: PlanPolicy
    render Views::Plans::ShowView.new(
      plan: read(Operations::TeamPlanning::Plan),
      scenarios: read(Operations::TeamPlanning::Scenarios)[:scenarios],
      members: read(Operations::TeamPlanning::PlanMembers)[:members],
      **layout
    )
  end

  private

  def index_view(error: nil)
    Views::Plans::IndexView.new(
      plans: Operations::TeamPlanning::Plans.call(context: pundit_user)[:plans],
      can_create: policy_for(TeamPlanningPlan).create?,
      error:,
      **layout
    )
  end

  def read(operation) = operation.call(context: pundit_user, params: { plan_id: params[:id] })

  def policy_for(record) = PlanPolicy.new(pundit_user, record)

  def layout
    { user: current_user, current_tenant: ActsAsTenant.current_tenant,
      tenants: ActsAsTenant.without_tenant { current_user.tenants.to_a } }
  end
end
