# frozen_string_literal: true

# Winds a unit down in a scenario.
class Operations::TeamPlanning::RetireUnit < Operations::Base
  include Operations::TeamPlanning::UnitChange

  description "Retire a live unit in a scenario of a Team Planning plan. Its people keep their place until an " \
              "assignment moves them. A unit with live sub-units is refused: move or retire them first. Setting " \
              "the unit again with team_planning_set_unit brings it back. scenario_id defaults to the baseline, " \
              "whose id is the plan's. Refused unless the caller is one of the plan's editors."
  category :write
  approval :mcp_client

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, allow_blank: false
  parameter :unit_id, String, required: true

  # @return [Hash] `{ plan_id, scenario_id, unit_id }`
  def perform
    plan = editable_plan!
    scenario_id = scenario_for(plan)
    map = resolved(plan, scenario_id)
    unit = live_unit!(map, uuid!(:unit_id))
    refuse!("Move or retire its sub-units first") if map.units.any? { it.parent_id == unit.id }

    refusing_bad_plans do
      handler.set_change(plan.id, ::TeamPlanning::Events::UnitRetired, scenario_id:, subject_id: unit.id,
                                                                                   end_state: as_it_stands(unit))
    end
    { plan_id: plan.id, scenario_id:, unit_id: unit.id }
  end
end
