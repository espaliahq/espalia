# frozen_string_literal: true

# Renames a plan. Only its creator may.
class Operations::TeamPlanning::RenamePlan < Operations::Base
  include Operations::TeamPlanning::PlanWrite

  description "Rename a Team Planning plan. Refused unless the caller created the plan."
  category :write
  approval :mcp_client

  parameter :plan_id, String, required: true
  parameter :name, String, required: true, allow_blank: false

  # @return [Hash] `{ plan_id, name }`
  def perform
    plan_id = plan_id!
    refusing_bad_plans { handler.rename_plan(plan_id, params[:name]) }
    { plan_id: plan_id, name: ::TeamPlanning::Repository.new.load_plan(plan_id).name }
  end
end
