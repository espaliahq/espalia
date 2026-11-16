# frozen_string_literal: true

# Writes, rewrites or clears the note on a change or pin
# [#273](https://github.com/espaliahq/espalia/issues/273). The note seals
# under its subject's key, and the history records each edit with who made it.
class Operations::TeamPlanning::NoteChange < Operations::Base
  include Operations::TeamPlanning::PlanWrite

  description "Write, rewrite or clear the note on a change or pin in a scenario of a Team Planning plan: why it " \
              "is in the plan. Give event_id as team_planning_history lists it, and leave note out or blank to " \
              "clear it. A note never changes what the scenario resolves to, can't be undone, and follows its " \
              "change through undo and redo. Refused for a change since undone, cleared or replaced in its " \
              "scenario, for a note over #{::TeamPlanning::PlanAggregate::NOTE_LIMIT} characters, or unless the " \
              "caller is an editor, for a change to a budget line without the see-pay right, and for a change to a person since forgotten. A note on a change to a person goes when they are forgotten. Any other note, such as " \
              "one on a unit, a position or a rule, stays until the plan is deleted, so keep personal details out of it."
  category :write
  approval :mcp_client

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true, schema: { description: "The scenario, or the plan's id for the baseline." }
  parameter :event_id, String, required: true
  parameter :note, String
  prose_fields :note

  # @return [Hash] `{ plan_id, scenario_id, event_id, noted }`, noted false when the note was cleared
  def perform
    plan_id = plan_id!
    scenario_id = scenario_id!(:scenario_id)
    event_id = uuid!(:event_id)
    refusing_bad_plans { handler.note_change(plan_id, scenario_id:, event_id:, note: params[:note]) }
    { plan_id:, scenario_id:, event_id:, noted: params[:note].to_s.strip.present? }
  rescue PlanKeyStore::Destroyed
    raise ParameterError, "This change's person has been forgotten, so its note can't be written"
  end
end
