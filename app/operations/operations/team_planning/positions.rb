# frozen_string_literal: true

# A scenario's open positions, resolved through {TeamPlanning::Resolution#call},
# with role and level names from the framework and a budget of committed
# (backfill) or planned (new) [#228](https://github.com/espaliahq/espalia/issues/228).
# Each names its occupants and its open FTE
# [#229](https://github.com/espaliahq/espalia/issues/229), and the people
# whose departure it backfills
# [#256](https://github.com/espaliahq/espalia/issues/256), so the
# forgotten-person audit walks it.
class Operations::TeamPlanning::Positions < Operations::Base
  include Operations::TeamPlanning::PlanRead
  include Operations::TeamPlanning::MapPayload

  description "List the open positions in a scenario of a Team Planning plan the caller is in: those its own " \
              "changes set, and those it inherits from the scenarios it follows. Each has its role and level " \
              "(with names from the framework; a name is null once the framework drops it), unit, FTE, basis, " \
              "cost_centre (the position's own label, null when it has none), and budget: 'committed' for a backfill, 'planned' for a new position. hiring_status and target_start are as SetPosition " \
              "takes them; opens_on is the day the seat opened: the first day of the step that opened it, the plan's base date for " \
              "one open from the start, or the day after the leaver it backfills goes. occupants lists each person placed " \
              "in it, with allocation and role; open_fte is its FTE less each occupant's allocation times their " \
              "FTE, below 0 when overfilled. backfill_for_ids lists the people whose departure it backfills: " \
              "empty for a backfill nobody is named for. `names` maps every person id to a name; a forgotten person reads as " \
              "\"#{Person::FORMER_MEMBER}\". Refused, as an unknown plan, unless the caller is a member."
  category :read
  approval :none

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true, schema: { description: "The scenario, or the plan's id for the baseline." }

  # @return [Hash] `{ plan_id, scenario_id, positions, names }`
  def perform
    plan = plan!
    scenario_id = scenario_id!(:scenario_id)
    map = refusing_bad_plans { ::TeamPlanning::Resolution.new(context:, plan:, scenario_id:).call }
    positions = positions_payload(map)
    ids = positions.flat_map { it[:occupants].pluck(:person_id) + it[:backfill_for_ids] }
    names = ids.to_h { [ it, map.name_of(it) ] }
    { plan_id: plan.id, scenario_id:, positions:, names: }
  end
end
