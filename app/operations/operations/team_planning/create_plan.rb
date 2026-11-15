# frozen_string_literal: true

# Starts a plan: a private draft of the organisation, read from the Org Graph
# as it stood on base_on.
#
# A tenant admin, or a planner linked to a person, may create one
# [#192](https://github.com/espaliahq/espalia/issues/192).
class Operations::TeamPlanning::CreatePlan < Operations::Base
  include Operations::TeamPlanning::PlanWrite
  include Operations::OrgGraph::DateParameter

  description "Create a Team Planning plan, a private draft of the organisation built on the Org Graph " \
              "as it stood on base_on (today by default). It covers the whole organisation, or with unit_ids only those units " \
              "and everything under them; the scope can be widened later. Only its members see it, and its creator is its first editor. " \
              "Refused unless the caller is a tenant admin or a planner, linked to a person."
  category :write
  approval :mcp_client

  parameter :name, String, required: true, allow_blank: false
  parameter :base_on, String, allow_blank: false, schema: DATE_SCHEMA
  parameter :unit_ids, Array, schema: { type: "array", items: { type: "string" }, description: "the units it covers, each with everything under it; none for the whole organisation" }

  # Only a tenant admin or a planner may create a plan; the handler checks it again.
  def policy_check
    authorize TeamPlanningPlan, :create?, policy_class: PlanPolicy
  end

  # @return [Hash] `{ plan_id, name, base_on }`
  def perform
    plan_id = SecureRandom.uuid_v7
    plan = refusing_bad_plans { handler.create_plan(plan_id, name: params[:name], base_on: base_on, unit_ids: params[:unit_ids].to_a) }
    { plan_id: plan_id, name: params[:name].squish, base_on: plan.base_on.iso8601 }
  end

  private

  def base_on = (parse_date(:base_on) || Date.current).iso8601
end
