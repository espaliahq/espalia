# frozen_string_literal: true

# Starts a plan: a private draft of the organisation, read from the Org Graph
# as it stood on base_on.
class Operations::TeamPlanning::CreatePlan < Operations::Base
  include Operations::TeamPlanning::PlanWrite
  include Operations::OrgGraph::DateParameter

  description "Create a Team Planning plan, a private draft of the organisation built on the Org Graph " \
              "as it stood on base_on (today by default). Only its members see it, and its creator is its first editor. " \
              "Refused unless the caller is a tenant admin or a planner, linked to a person."
  category :write
  approval :mcp_client

  parameter :name, String, required: true, allow_blank: false
  parameter :base_on, String, allow_blank: false, schema: DATE_SCHEMA

  # Only a tenant admin or a planner may create a plan; the handler checks it again.
  def policy_check
    authorize TeamPlanningPlan, :create?, policy_class: PlanPolicy
  end

  # @return [Hash] `{ plan_id, name, base_on }`
  def perform
    plan_id = SecureRandom.uuid_v7
    plan = refusing_bad_plans { handler.create_plan(plan_id, name: params[:name], base_on: base_on) }
    { plan_id: plan_id, name: plan.name, base_on: plan.base_on.iso8601 }
  end

  private

  def base_on = (parse_date(:base_on) || Date.current).iso8601
end
