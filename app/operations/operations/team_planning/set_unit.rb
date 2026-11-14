# frozen_string_literal: true

# Creates a unit in a scenario, or renames or moves one it already has.
class Operations::TeamPlanning::SetUnit < Operations::Base
  include Operations::TeamPlanning::UnitChange

  description "Create, rename or move a unit in a scenario of a Team Planning plan. Without unit_id it creates a " \
              "unit, which needs a name and a level_id from the Org Graph taxonomy. With unit_id (an Org Graph " \
              "unit, or one the plan created) it changes that unit: whatever you leave out stays as the scenario " \
              "has it, and a retired unit comes back. parent_id places it beneath a live unit at a higher level; " \
              "top_level true puts it at the top. A unit's level can't change. scenario_id defaults to the " \
              "baseline, whose id is the plan's. Refused unless the caller is one of the plan's editors."
  category :write
  approval :mcp_client

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, allow_blank: false
  parameter :unit_id, String, allow_blank: false
  parameter :name, String, allow_blank: false,
    schema: { description: "What the unit is, such as 'Payments'. Don't put a person's name in it." }
  parameter :parent_id, String, allow_blank: false
  parameter :top_level, :boolean
  parameter :level_id, String, allow_blank: false

  # @return [Hash] `{ plan_id, scenario_id, unit_id, name, parent_id, level_id }`
  def perform
    plan = editable_plan!
    scenario_id = scenario_for(plan)
    map = resolved(plan, scenario_id)
    unit_id = params[:unit_id] && uuid!(:unit_id)
    current = unit_id && (map.units + map.retired_units).find { it.id == unit_id }
    refuse!("There is no such unit in this scenario") if unit_id && !current

    level_id = params[:level_id] ? uuid!(:level_id) : current&.level_id
    parent_id = parent_for(current)
    check_level!(map, current, level_id, parent_id)
    unit_id ||= SecureRandom.uuid_v7
    end_state = { name: params[:name] || current&.name, parent_id:, level_id: }

    stored = refusing_bad_plans do
      handler.set_change(plan.id, ::TeamPlanning::Events::UnitSet, scenario_id:, subject_id: unit_id, end_state:)
    end
    { plan_id: plan.id, scenario_id:, unit_id:, **stored.changes_in(scenario_id).last.data.slice(:name, :parent_id, :level_id) }
  end

  private

  def parent_for(current)
    refuse!("Give parent_id or top_level, not both") if params[:top_level] && params[:parent_id]
    return nil if params[:top_level]

    params[:parent_id] ? uuid!(:parent_id) : current&.parent_id
  end

  def check_level!(map, current, level_id, parent_id)
    refuse!("A new unit needs a level_id") unless level_id
    refuse!("A unit's level can't change: create a unit at the new level instead") if current && current.level_id != level_id
    refuse!("Level is not in the taxonomy") unless level_ids.include?(level_id)
    return unless parent_id

    parent = map.units.find { it.id == parent_id } || refuse!("The parent must be a live unit in this scenario")
    if current && ([ current.id ] + descendant_ids(map, current.id)).include?(parent_id)
      refuse!("A unit can't move beneath itself or a unit below it")
    end
    refuse!("A parent must sit at a higher level") unless level_ids.index(parent.level_id).to_i < level_ids.index(level_id)
  end
end
