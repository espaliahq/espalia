# frozen_string_literal: true

ForgottenPersonAudit.walk("team_planning_undo_step") do
  TeamPlanning::CommandHandler.new(actor: lead_context)
    .set_change(@plan_id, TeamPlanning::Events::AssignmentSet, scenario_id: @scenario_id, subject_id: @quinn.id,
                end_state: { placements: [ { unit_id: @unit_id, allocation: 1 } ] })
  { plan_id: @plan_id, scenario_id: @scenario_id }
end
