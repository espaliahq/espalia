# frozen_string_literal: true

# Brings an archived plan back. Only an editor may.
class Operations::TeamPlanning::RestorePlan < Operations::Base
  include Operations::TeamPlanning::PlanWrite

  description "Restore an archived Team Planning plan, so it takes changes and is checked against the organisation again. Refused unless the caller is one of its editors, or when the plan isn't archived."
  category :write
  approval :mcp_client

  parameter :plan_id, String, required: true

  # @return [Hash] `{ plan_id, archived }`
  def perform
    plan_id = plan_id!
    plan = refusing_bad_plans { handler.restore_plan(plan_id) }
    { plan_id:, archived: plan.archived? }
  end
end
