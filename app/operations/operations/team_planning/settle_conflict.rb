# frozen_string_literal: true

# Settles a conflict an update to today carried forward
# [#336](https://github.com/espaliahq/espalia/issues/336): keep the plan, or
# follow reality. A conflict read before any update can't be settled yet, as
# keeping it would change nothing the Org Graph reads.
class Operations::TeamPlanning::SettleConflict < Operations::Base
  include Operations::TeamPlanning::PlanWrite

  description "Settle a conflict an update to today carried forward in a scenario of a Team Planning plan: one " \
              "team_planning_status reads as conflicting with a since. choice 'plan' keeps the planned change, " \
              "set again in the scenario, pinned again with the same source when the scenario pinned it, or pinned " \
              "there when it inherits the change (set again when the change's value is sealed, as a level is), with " \
              "the change's own note unless given another. choice 'reality' sets what the Org Graph holds today in " \
              "this scenario alone, a cleared level as no level and a missing allocation as unknown, so " \
              "the scenario that made the change, and its other children, keep it; settled in the scenario that made " \
              "the change, it reaches the children that inherit it. Either way status stops reporting the conflict, " \
              "and team_planning_history marks the write with settles. Refused for a conflict no update carried " \
              "forward (update the plan to today first), one status no longer reads as conflicting, following " \
              "reality for a unit succession, for a budget line that carries an amount without the see-pay right, or unless the caller is an editor."
  category :write
  approval :mcp_client

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true, schema: { description: "The scenario, or the plan's id for the baseline." }
  parameter :subject_id, String, required: true, allow_blank: false
  parameter :facet, String, required: true, allow_blank: false
  parameter :choice, String, required: true, allowed: ::TeamPlanning::PlanAggregate::SETTLE_CHOICES
  parameter :note, String
  prose_fields :note

  # @return [Hash] `{ plan_id, scenario_id, subject_id, facet, choice }`
  def perform
    plan_id = plan_id!
    scenario_id = scenario_id!(:scenario_id)
    key = { subject_id: params[:subject_id], facet: params[:facet] }
    refusing_bad_plans do
      ensure_conflicting!(plan_id, scenario_id, key)
      handler.settle_conflict(plan_id, scenario_id:, **key, choice: params[:choice], note: params[:note])
    end
    { plan_id:, scenario_id:, **key, choice: params[:choice] }
  rescue PlanKeyStore::Destroyed
    raise ParameterError, "This change's person has been forgotten, so it can't be settled"
  end

  private

  # The plan remembers which conflicts an update carried forward, but only
  # status knows whether the Org Graph has since caught up, or the person was forgotten.
  def ensure_conflicting!(plan_id, scenario_id, key)
    plan = TeamPlanningPlan.includes(:members).find_by(id: plan_id)
    raise ::TeamPlanning::Error, "No such plan" unless plan && PlanPolicy.new(context, plan).update?

    report = ::TeamPlanning::Status.new(context:, plan:, scenario_id:).call
    entry = report.statuses.find { it.subject_id == key[:subject_id] && it.facet.to_s == key[:facet] }
    return if entry&.status.to_s == "conflicting"

    raise ::TeamPlanning::Error, "Status doesn't read this as conflicting, so there is nothing to settle"
  end
end
