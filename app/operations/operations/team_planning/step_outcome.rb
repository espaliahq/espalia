# frozen_string_literal: true

# A closed step's plan beside what happened, unit by unit
# ([#466](https://github.com/espaliahq/espalia/issues/466)). Heads and names
# only: {TeamPlanning::StepOutcome} reads no level, pay, cost or budget, and
# says nothing of where someone outside the plan's scope went. Walked by the
# privacy test and the forgotten-person audit.
class Operations::TeamPlanning::StepOutcome < Operations::Base
  include Operations::TeamPlanning::PlanRead

  description "Compare a closed step of a Team Planning plan the caller is in with what happened: each unit the plan " \
              "covers, by unit id, under the plan's name for it, as the organisation stood on the step's last day " \
              "(ends_on). known_on is null when the Org Graph is read as it stands now, or the archive day for an " \
              "archived plan. Each unit carries planned_heads and actual_heads, and people with an outcome: " \
              "as_planned, planned_not_here (planned in this unit but not there, with no word on where they are), " \
              "here_not_planned, or hire_not_filled (a placeholder hire the plan added). seats are the plan's " \
              "positions in the unit: filled_by_id names the person the plan placed in the seat when they are in " \
              "its unit, else null; someone new in the unit never fills a seat. hire_id and hire_name name a " \
              "placeholder hire holding a seat not filled. Refused for a step that isn't closed, reopened ones " \
              "included, and, as an unknown plan, unless the caller is a member."
  category :read
  approval :none

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true, schema: { description: "The closed step." }

  # @return [Hash] `{ plan_id, scenario_id, ends_on, known_on, units }`
  def perform
    plan = plan!
    scenario_id = scenario_id!(:scenario_id)
    known_scenario!(plan, scenario_id)
    outcome = refusing_bad_plans { ::TeamPlanning::StepOutcome.new(context:, plan:, scenario_id:).call }
    { plan_id: plan.id, scenario_id:, ends_on: outcome.ends_on.iso8601, known_on: outcome.known_on&.iso8601,
      units: outcome.units.map { unit(it, outcome.names) } }
  end

  private

  def unit(row, names)
    { unit_id: row.unit_id, name: row.name, planned_heads: row.planned_heads, actual_heads: row.actual_heads,
      people: row.people.map { { person_id: it.person_id, name: names.fetch(it.person_id), outcome: it.outcome } },
      seats: row.seats.map do
        { position_id: it.position_id, filled_by_id: it.filled_by_id, filled_by_name: it.filled_by_id && names.fetch(it.filled_by_id),
          hire_id: it.hire_id, hire_name: it.hire_id && names.fetch(it.hire_id) }
      end }
  end
end
