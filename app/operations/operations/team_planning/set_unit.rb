# frozen_string_literal: true

# Creates a unit in a scenario, or renames or moves one it already has.
class Operations::TeamPlanning::SetUnit < Operations::Base
  include Operations::TeamPlanning::UnitChange
  include Operations::TeamPlanning::ChangeWrite

  description "Create, rename or move a unit in a scenario of a Team Planning plan. Without unit_id it creates a " \
              "unit, which needs a name and a level_id from the Org Graph taxonomy. With unit_id (an Org Graph " \
              "unit, or one the plan created) it changes that unit: whatever you leave out stays as the scenario " \
              "has it, and a retired unit comes back. parent_id places it beneath a live unit of a kind its own kind " \
              "can sit under; top_level true puts it at the top, if its kind can sit there. A unit's level can't change. scenario_id defaults to the " \
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
  forbids_when :parent_id, if: :top_level, equals: true, message: "Give parent_id or top_level, not both"
  requires_any_of :unit_id, :name
  requires_any_of :unit_id, :level_id

  # @return [Hash] `{ plan_id, scenario_id, unit_id, name, parent_id, level_id }`
  def perform
    scenario_id = scenario_for
    unit_id = params[:unit_id] && uuid!(:unit_id)
    subject_id = unit_id || SecureRandom.uuid_v7
    stored = set_unit_changes!(scenario_id) do |map|
      [ { kind: ::TeamPlanning::Events::UnitSet, scenario_id:, subject_id:, end_state: end_state_in(map, unit_id) } ]
    end
    { plan_id: plan_id!, scenario_id:, unit_id: subject_id,
      **stored.changes_in(scenario_id).last.data.slice(:name, :parent_id, :level_id) }
  end

  private

  def end_state_in(map, unit_id)
    current = unit_id && ((map.units + map.retired_units).find { it.id == unit_id } || refuse!("There is no such unit in this scenario"))
    level_id = params[:level_id] ? uuid!(:level_id) : current&.level_id
    parent_id = parent_for(current)
    check_level!(map, current, level_id, parent_id)
    { name: params[:name] || current&.name, parent_id:, level_id: }
  end

  def parent_for(current)
    return nil if params[:top_level]

    params[:parent_id] ? uuid!(:parent_id) : current&.parent_id
  end

  def check_level!(map, current, level_id, parent_id)
    refuse!("A unit's level can't change: create a unit at the new level instead") if current && current.level_id != level_id
    kind = taxonomy.kind(level_id)
    refuse!("Level is not in the taxonomy") unless current || kind
    returning = current && map.units.none? { it.id == current.id }
    return unless current.nil? || returning || parent_id != current.parent_id
    return check_top!(kind) unless parent_id

    parent = map.units.find { it.id == parent_id } || refuse!("The parent must be a live unit in this scenario")
    if current && ([ current.id ] + descendant_ids(map, current.id)).include?(parent_id)
      refuse!("A unit can't move beneath itself or a unit below it")
    end
    parent_kind = taxonomy.kind(parent.level_id)
    refuse!("Level is no longer in the taxonomy, so the unit can't be placed") unless kind && parent_kind
    refuse!("#{kind.name} can't sit under #{parent_kind.name}") unless taxonomy.allows?(kind.id, beneath: parent_kind.id)
  end

  def check_top!(kind)
    refuse!("Level is no longer in the taxonomy, so the unit can't be placed") unless kind
    refuse!("#{kind.name} can't sit at the top") unless kind.top?
  end
end
