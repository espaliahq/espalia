# frozen_string_literal: true

# Starts a plan: a private draft of the organisation, read from the Org Graph
# as it stood on base_on.
class Operations::TeamPlanning::CreatePlan < Operations::Base
  include Operations::TeamPlanning::PlanWrite

  description "Create a Team Planning plan, a private draft of the organisation built on the Org Graph " \
              "as it stood on base_on (today by default). Only its creator sees it. Refused unless the " \
              "caller is a tenant admin linked to a person."
  category :write
  approval :mcp_client

  parameter :name, String, required: true, allow_blank: false
  parameter :base_on, String, allow_blank: false

  def policy_check
    authorize TeamPlanningPlan, :create?, policy_class: PlanPolicy
  end

  # @return [Hash] `{ plan_id, name, base_on }`
  def perform
    plan_id = SecureRandom.uuid_v7
    refusing_bad_plans { handler.create_plan(plan_id, name: params[:name], base_on: base_on) }
    plan = ::TeamPlanning::Repository.new.load_plan(plan_id)
    { plan_id: plan_id, name: plan.name, base_on: plan.base_on.iso8601 }
  end

  private

  def base_on
    return Date.current.iso8601 unless params[:base_on]

    Date.iso8601(params[:base_on]).iso8601
  rescue Date::Error
    raise Operations::Base::ParameterError, "base_on must be a date like 2026-11-14, got #{params[:base_on].inspect}"
  end
end
