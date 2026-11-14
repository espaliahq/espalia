# frozen_string_literal: true

ForgottenPersonAudit.walk("team_planning_timeline") do
  TeamPlanning::CommandHandler.new(actor: lead_context)
    .set_change(@plan_id, TeamPlanning::Events::AssignmentSet, scenario_id: @plan_id, subject_id: @quinn.id,
                end_state: { placements: [ { unit_id: @unit_id, allocation: 0.5, role: "Lead" } ] })
  { plan_id: @plan_id, scenario_id: @plan_id }
end
