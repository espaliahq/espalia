# frozen_string_literal: true

# The audit's plan stands on tomorrow, which a preview refuses, so this walks a
# plan that stands on yesterday: its drift names Quinn.
ForgottenPersonAudit.walk("team_planning_rebase_preview") do
  plan_id = SecureRandom.uuid_v7
  TeamPlanning::CommandHandler.new(actor: lead_context).create_plan(plan_id, name: "Last week", base_on: Date.current - 1)
  { plan_id: }
end
