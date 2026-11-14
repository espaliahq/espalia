# frozen_string_literal: true

ForgottenPersonAudit.walk("team_planning_positions") do
  handler = TeamPlanning::CommandHandler.new(actor: lead_context)
  position_id = SecureRandom.uuid_v7
  handler.set_change(@plan_id, TeamPlanning::Events::PositionSet, scenario_id: @plan_id, subject_id: position_id,
                     end_state: { role_id: @fx.engineer.role_id, level_id: @fx.e_levels.fetch(2).level_id, unit_id: @unit_id, fte: 1, basis: "backfill" })
  handler.set_change(@plan_id, TeamPlanning::Events::AssignmentSet, scenario_id: @plan_id, subject_id: @quinn.id,
                     end_state: { placements: [ { position_id:, allocation: 1 } ] })
  { plan_id: @plan_id, scenario_id: @plan_id }
end
