# frozen_string_literal: true

ForgottenPersonAudit.walk("team_planning_step_outcome") do
  plan_id, step_id = SecureRandom.uuid_v7, SecureRandom.uuid_v7
  handler = TeamPlanning::CommandHandler.new(actor: lead_context)
  handler.create_plan(plan_id, name: "Closed", base_on: Date.current)
  handler.fork_scenario(plan_id, step_id, parent_id: plan_id, relation: "then", name: "Q1", ends_on: Date.current + 30)
  travel_to(Date.current + 32) { handler.close_step(plan_id, step_id) }
  { plan_id:, scenario_id: step_id }
end
