# frozen_string_literal: true

# Settles a conflict an update to today carried forward
# [#336](https://github.com/espaliahq/espalia/issues/336): keep the plan, or
# follow reality. A conflict read before any update can't be settled yet, as
# keeping it would change nothing the Org Graph reads.
class Operations::TeamPlanning::SettleConflict < Operations::Base
  include Operations::TeamPlanning::PlanWrite

  description "Settle a conflict an update to today carried forward in a scenario of a Team Planning plan: one " \
              "team_planning_status reads as conflicting with a since. choice 'plan' keeps the planned change, " \
              "set again in the scenario, or pinned there when it inherits the change, with the change's own note " \
              "unless given another. choice 'reality' sets what the Org Graph holds today in this scenario alone, so " \
              "the scenario that made the change, and its other children, keep it. Either way status stops reporting " \
              "the conflict, and team_planning_history marks the write with settles. Refused for a conflict no " \
              "update carried forward (update the plan to today first), a value the plan keeps private, or unless " \
              "the caller is an editor."
  category :write
  approval :mcp_client

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true, schema: { description: "The scenario, or the plan's id for the baseline." }
  parameter :subject_id, String, required: true, allow_blank: false
  parameter :facet, String, required: true, allow_blank: false
  parameter :choice, String, required: true, schema: { enum: ::TeamPlanning::PlanAggregate::SETTLE_CHOICES }
  parameter :note, String
  prose_fields :note

  # @return [Hash] `{ plan_id, scenario_id, subject_id, facet, choice }`
  def perform
    plan_id = plan_id!
    scenario_id = scenario_id!(:scenario_id)
    key = { subject_id: params[:subject_id], facet: params[:facet] }
    refusing_bad_plans { handler.settle_conflict(plan_id, scenario_id:, **key, choice: params[:choice], note: params[:note]) }
    { plan_id:, scenario_id:, **key, choice: params[:choice] }
  rescue PlanKeyStore::Destroyed
    raise ParameterError, "This change's person has been forgotten, so its note can't be kept"
  end
end
