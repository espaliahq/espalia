# frozen_string_literal: true

# Updates a plan to today ([#263](https://github.com/espaliahq/espalia/issues/263)).
# The conflicts it records are found afresh at the moment of the update, so a
# preview read earlier can't leave one out.
class Operations::TeamPlanning::RebasePlan < Operations::Base
  include Operations::TeamPlanning::PlanRead
  include Operations::OrgGraph::DateParameter

  description "Update a Team Planning plan to today (a UTC day): its base moves to today and every scenario " \
              "reads the Org Graph as of it, with nothing else rewritten. The first step after the baseline " \
              "starts on the new base. Read team_planning_rebase_preview first and pass the base_on it gave, so " \
              "an update made since is refused rather than taken in unseen. A change that conflicts with the Org " \
              "Graph at that moment stays conflicting in team_planning_status until it reads done or is set, " \
              "cleared or undone in its scenario. Undo does not reverse an update: a base only moves forward. " \
              "Refused when the plan already stands on today or a day still to come, when the first step would " \
              "end before today, naming it, and, as an unknown plan, unless the caller is an editor."
  category :write
  approval :mcp_client

  parameter :plan_id, String, required: true
  parameter :base_on, String, required: true, allow_blank: false,
    schema: DATE_SCHEMA.merge(description: "The base the preview read, YYYY-MM-DD.")

  # @return [Hash] `{ plan_id, base_on, previous_base_on, conflicts }`
  def perform
    plan = plan!
    raise Operations::Base::ParameterError, "No such plan" unless PlanPolicy.new(context, plan).update?

    expected_base_on = parse_date(:base_on)
    refusing_bad_plans do
      preview = ::TeamPlanning::RebasePreview.new(context:, plan:).call
      handler.rebase_plan(plan.id, base_on: preview.to, expected_base_on:, conflicts: preview.conflicts)
      { plan_id: plan.id, base_on: preview.to.iso8601, previous_base_on: plan.base_on.iso8601, conflicts: preview.conflicts }
    end
  end
end
