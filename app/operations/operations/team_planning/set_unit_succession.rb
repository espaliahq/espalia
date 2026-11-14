# frozen_string_literal: true

# States in a scenario which units carry on from which, retiring the live
# predecessors in the same write, as the Org Graph's own succession does.
class Operations::TeamPlanning::SetUnitSuccession < Operations::Base
  include Operations::TeamPlanning::UnitChange

  IDS = { type: "array", items: { type: "string" }, minItems: 1 }.freeze

  description "Say which units carry on from which in a scenario of a Team Planning plan: a split (one " \
              "predecessor, several successors), a merge (several predecessors, one successor) or a " \
              "replacement. Every live predecessor retires in the same write. Successors must be live, no unit " \
              "can succeed itself, and no chain of successions may loop back. Without succession_id it records " \
              "a new succession; with one it restates it, and a unit the old statement retired stays retired until " \
              "team_planning_set_unit sets it again. scenario_id defaults to the baseline, whose id is the " \
              "plan's. Refused unless the caller is one of the plan's editors."
  category :write
  approval :mcp_client

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, allow_blank: false
  parameter :succession_id, String, allow_blank: false
  parameter :predecessor_ids, Array, required: true, schema: IDS.merge(description: "the units that came before")
  parameter :successor_ids, Array, required: true, schema: IDS.merge(description: "live units that carry on from them")

  # @return [Hash] `{ plan_id, scenario_id, succession_id, predecessor_ids, successor_ids, retired_ids }`
  def perform
    plan = editable_plan!
    scenario_id = scenario_for(plan)
    map = resolved(plan, scenario_id)
    succession_id = succession_for(map)
    predecessor_ids, successor_ids = ids(:predecessor_ids), ids(:successor_ids)
    check!(map, succession_id, predecessor_ids, successor_ids)
    retiring = map.units.select { predecessor_ids.include?(it.id) }
    check_retirable!(map, retiring.map(&:id))

    refusing_bad_plans { handler.set_changes(plan.id, changes(scenario_id, succession_id, predecessor_ids, successor_ids, retiring)) }
    { plan_id: plan.id, scenario_id:, succession_id:, predecessor_ids: predecessor_ids.sort,
      successor_ids: successor_ids.sort, retired_ids: retiring.map(&:id).sort }
  end

  private

  def succession_for(map)
    return SecureRandom.uuid_v7 unless params[:succession_id]

    id = uuid!(:succession_id)
    map.successions.any? { it.id == id } ? id : refuse!("There is no such succession in this scenario")
  end

  def ids(name)
    Array(params[name]).map do |value|
      value.is_a?(String) && value.match?(UUID_RE) ? value.downcase : refuse!("#{name} must hold unit ids")
    end.uniq
  end

  def check!(map, succession_id, predecessor_ids, successor_ids)
    known = (map.units + map.retired_units).map(&:id)
    refuse!("There is no such unit in this scenario") unless (predecessor_ids + successor_ids).all? { known.include?(it) }
    refuse!("A unit can't succeed itself") if predecessor_ids.intersect?(successor_ids)
    refuse!("A successor must be live") unless successor_ids.all? { |id| map.units.any? { it.id == id } }

    others = map.successions.reject { it.id == succession_id }
    refuse!("A unit can't come to precede itself") if preceding(others, predecessor_ids).intersect?(successor_ids)
  end

  # The units that come before these, at any distance, and these themselves.
  def preceding(successions, unit_ids, seen = [])
    fresh = unit_ids - seen
    return seen if fresh.empty?

    earlier = successions.select { it.successor_ids.intersect?(fresh) }.flat_map(&:predecessor_ids)
    preceding(successions, earlier, seen + fresh)
  end

  def check_retirable!(map, retiring)
    blocked = map.units.find { |unit| retiring.include?(unit.parent_id) && !retiring.include?(unit.id) }
    refuse!("Move or retire the sub-units of each predecessor first") if blocked
  end

  def changes(scenario_id, succession_id, predecessor_ids, successor_ids, retiring)
    retiring.map { { kind: ::TeamPlanning::Events::UnitRetired, scenario_id:, subject_id: it.id, end_state: as_it_stands(it) } } +
      [ { kind: ::TeamPlanning::Events::UnitSuccessionSet, scenario_id:, subject_id: succession_id,
          end_state: { predecessor_ids:, successor_ids: } } ]
  end
end
