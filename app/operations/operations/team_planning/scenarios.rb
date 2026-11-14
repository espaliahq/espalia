# frozen_string_literal: true

# A plan's scenarios: the baseline, and each scenario with its parent,
# relation and the period the tree gives it.
class Operations::TeamPlanning::Scenarios < Operations::Base
  include Operations::TeamPlanning::PlanRead

  description "List the scenarios of a Team Planning plan the caller is in. The baseline comes first: its id is " \
              "the plan's, it stands on the base date and has no parent, relation or end. Each other scenario has " \
              "its parent_id, its relation ('then' follows the parent, 'instead' is an alternative to it) and its " \
              "period. Refused, as an unknown plan, unless the caller is a member."
  category :read
  approval :none

  parameter :plan_id, String, required: true

  # @return [Hash] `{ plan_id, scenarios: [{ scenario_id, parent_id, relation, name, starts_on, ends_on }] }`
  def perform
    plan = plan!
    rows = TeamPlanningScenario.where(plan_id: plan.id).order(:created_at, :id)
    scenarios = rows.sort_by { it.baseline? ? 0 : 1 }.map do |row|
      { scenario_id: row.id, parent_id: row.parent_id, relation: row.relation, name: row.name,
        starts_on: row.starts_on.iso8601, ends_on: row.ends_on&.iso8601 }
    end
    { plan_id: plan.id, scenarios: }
  end
end
