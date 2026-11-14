# frozen_string_literal: true

ForgottenPersonAudit.walk("team_planning_attention") do
  TeamPlanning::CommandHandler.new(actor: lead_context)
    .set_change(@plan_id, TeamPlanning::Events::AssignmentSet, scenario_id: @plan_id, subject_id: @quinn.id,
                end_state: { placements: [ { position_id: SecureRandom.uuid_v7, allocation: 1 } ] })
  { plan_id: @plan_id, scenario_id: @plan_id }
end
