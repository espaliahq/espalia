# frozen_string_literal: true

# A scenario's units and successions, resolved.
class Operations::TeamPlanning::Units < Operations::Base
  include Operations::TeamPlanning::UnitChange

  description "List the units of a scenario in a Team Planning plan the caller is in, resolved: the baseline's " \
              "units with the scenario's changes and its ancestors' applied. units are live, by name, each with " \
              "its parent_id and level_id; retired_units are those a scenario retired; successions say which " \
              "units carry on from which. scenario_id defaults to the baseline, whose id is the plan's. Refused, " \
              "as an unknown plan, unless the caller is a member."
  category :read
  approval :none

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, allow_blank: false

  # @return [Hash] `{ plan_id, scenario_id, units, retired_units, successions }`
  def perform
    plan = plan!
    scenario_id = scenario_for
    map = refusing_bad_plans { ::TeamPlanning::Resolution.new(context:, plan:, scenario_id:).structure }
    on_map = map.scope_ids && map.known_unit_ids
    { plan_id: plan.id, scenario_id:, units: map.units.map { unit_row(it, on_map) }, retired_units: map.retired_units.map { unit_row(it, on_map) },
      successions: map.successions.map { { succession_id: it.id, predecessor_ids: it.predecessor_ids, successor_ids: it.successor_ids } } }
  end

  private

  # A scope root's parent sits outside the plan, so a scoped plan shows it at the top, as the scenario map does.
  def unit_row(unit, on_map)
    parent_id = unit.parent_id unless on_map && !on_map.include?(unit.parent_id)
    { unit_id: unit.id, name: unit.name, parent_id:, level_id: unit.level_id }
  end
end
