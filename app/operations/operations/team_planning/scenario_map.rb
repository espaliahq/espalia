# frozen_string_literal: true

# One scenario's whole organisation, resolved, in the baseline read's shape
# [#229](https://github.com/espaliahq/espalia/issues/229). A person's
# allocation_total is null when the HRIS gave a place no allocation: that is
# unknown, and a check must not read it as under-allocated. Walked by the
# privacy test and the forgotten-person audit.
class Operations::TeamPlanning::ScenarioMap < Operations::Base
  include Operations::TeamPlanning::PlanRead
  include Operations::TeamPlanning::MapPayload

  description "Get one scenario of a Team Planning plan the caller is in, resolved: the baseline with the " \
              "changes of every scenario it follows and its own. Units carry their parent, level and owners. " \
              "People carry their facts and each place they hold (a unit, or a position with its unit), with " \
              "allocation and role, plus allocation_total: over 1 when over-allocated, null when unknown " \
              "because the HRIS gave no allocation. unassigned_ids are the people in no live unit. Positions " \
              "carry their occupants, open_fte and backfill_for_ids (whose departure each backfills). " \
              "People carry their reporting line (manager_id, or manager_position_id for a manager being hired) " \
              "and leaving, with leaves_on (null without a date) and backfill_position_id, when they leave in this scenario's step; departed lists " \
              "those who left in an earlier step, with their backfill. unresolved lists people the plan places who aren't on the " \
              "map, with why: 'joined after the base date' (team_planning_rebase_plan brings them in) or " \
              "'has left'. `names` maps every person id to a name; a forgotten person reads as " \
              "\"#{Person::FORMER_MEMBER}\". known_on is null when the Org Graph is read as it stands now. Refused, as an unknown plan, unless the caller is a member."
  category :read
  approval :none

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true, schema: { description: "The scenario, or the plan's id for the baseline." }

  # @return [Hash] `{ plan_id, scenario_id, base_on, known_on, units, people, unassigned_ids, positions, unresolved, departed, names }`
  def perform
    plan = plan!
    scenario_id = scenario_id!(:scenario_id)
    map = refusing_bad_plans { ::TeamPlanning::Resolution.new(context:, plan:, scenario_id:).call }
    { plan_id: plan.id, scenario_id:, **map_payload(map, plan:) }
  end
end
