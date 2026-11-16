# frozen_string_literal: true

# Updates a plan to today ([#263](https://github.com/espaliahq/espalia/issues/263)).
# The conflicts it records are found afresh under the plan's lock, so neither
# a preview read earlier nor a change made since can leave one out.
class Operations::TeamPlanning::RebasePlan < Operations::Base
  include Operations::TeamPlanning::PlanRead
  include Operations::OrgGraph::DateParameter

  description "Update a Team Planning plan to today (in the tenant's time zone): its base moves to today and every scenario " \
              "reads the Org Graph as of it, with nothing else rewritten. A first step after the baseline that " \
              "starts before the new base starts on it; one that starts later keeps its start. Read team_planning_rebase_preview first and pass the base_on it gave, so " \
              "an update made since is refused rather than taken in unseen. A change that conflicts with the Org " \
              "Graph at that moment stays conflicting in team_planning_status while the scenario still " \
              "resolves to that change: a set, pin, clear or undo ends it. Undo does not reverse an update: a base only moves forward. " \
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
    today = Tenant.today
    refusing_bad_plans do
      conflicts = []
      handler.rebase_plan(plan.id, base_on: today, expected_base_on:) do
        conflicts = ::TeamPlanning::RebasePreview.new(context:, plan: plan.reload, today:).call.conflicts
      end
      { plan_id: plan.id, base_on: today.iso8601, previous_base_on: expected_base_on.iso8601, conflicts: }
    end
  end
end
