# frozen_string_literal: true

# Keeps what a scenario inherits for one facet of one subject, as it resolves
# now. Reconcile (4.5) calls it to keep the plan
# [#239](https://github.com/espaliahq/espalia/issues/239).
class Operations::TeamPlanning::PinChange < Operations::Base
  include Operations::TeamPlanning::ChangeWrite

  description "Pin what a scenario of a Team Planning plan inherits for one facet of one subject, as it resolves " \
              "now, so a later change in its parent no longer reaches it: the 'keep the plan' answer when " \
              "reconciling. facet is as team_planning_overrides lists it, such as 'rule:<name>'. The pin records " \
              "where the value came from. Refused for the baseline, for a facet the scenario already changes, or " \
              "unless the caller is an editor."
  category :write
  approval :mcp_client

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true
  parameter :subject_id, String, required: true, allow_blank: false
  parameter :facet, String, required: true, allow_blank: false

  # @return [Hash] the pin, as team_planning_overrides lists it; just the key, unpinned, once someone has already cleared it
  def perform
    plan_id = plan_id!
    scenario_id = scenario_id!(:scenario_id)
    refusing_bad_plans { handler.pin_change(plan_id, scenario_id:, subject_id: params[:subject_id], facet: params[:facet], note: params[:note]) }
    plan = TeamPlanningPlan.find(plan_id)
    key = { subject_id: params[:subject_id], facet: params[:facet] }
    pinned = Operations::TeamPlanning::Overrides.listed(context:, plan:, scenario_id:).find { it.slice(:subject_id, :facet) == key }
    # Another editor can clear the pin between the write and this read.
    (pinned || { **key, pinned: false }).merge(plan_id:, scenario_id:)
  end
end
