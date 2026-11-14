# frozen_string_literal: true

# Renames a plan. Only an editor may.
class Operations::TeamPlanning::RenamePlan < Operations::Base
  include Operations::TeamPlanning::PlanWrite

  description "Rename a Team Planning plan. Refused unless the caller is one of its editors."
  category :write
  approval :mcp_client

  parameter :plan_id, String, required: true
  parameter :name, String, required: true, allow_blank: false

  # @return [Hash] `{ plan_id, name }`
  def perform
    plan_id = plan_id!
    plan = refusing_bad_plans { handler.rename_plan(plan_id, params[:name]) }
    { plan_id: plan_id, name: plan.name }
  end
end
