# frozen_string_literal: true

# Sets a plan aside without deleting it. Only an editor may.
class Operations::TeamPlanning::ArchivePlan < Operations::Base
  include Operations::TeamPlanning::PlanWrite

  description "Archive a Team Planning plan: it keeps everything, takes no changes and is no longer checked against the organisation until an editor restores it. Its members can still leave, and it can still be deleted. Refused unless the caller is one of its editors, or when the plan is already archived."
  category :write
  approval :mcp_client

  parameter :plan_id, String, required: true

  # @return [Hash] `{ plan_id, archived }`
  def perform
    plan_id = plan_id!
    plan = refusing_bad_plans { handler.archive_plan(plan_id) }
    { plan_id:, archived: plan.archived? }
  end
end
