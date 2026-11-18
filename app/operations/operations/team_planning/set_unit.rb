# frozen_string_literal: true

# Creates a unit in a scenario, or renames or moves one it already has.
class Operations::TeamPlanning::SetUnit < Operations::Base
  include Operations::TeamPlanning::UnitChange
  include Operations::TeamPlanning::ChangeWrite

  description "Create, rename or move a unit in a scenario of a Team Planning plan. Without unit_id it creates a " \
              "unit, which needs a name and a level_id from the Org Graph taxonomy. With unit_id (an Org Graph " \
              "unit, or one the plan created) it changes that unit: whatever you leave out stays as the scenario " \
              "has it, and a retired unit comes back. parent_id places it beneath a live unit of a kind its own kind " \
              "can sit under; top_level true puts it at the top, if its kind can sit there. Beneath a unit with a " \
              "structure of its own, a unit takes that structure's types and sits at its top. An Org Graph unit's " \
              "level can't change; a unit the plan created may take another level of the structure it sits in, and " \
              "only so, with nothing beneath it, may it move into another structure. scenario_id defaults to the " \
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

  # A unit sits in the structure in force at its planned parent, and beneath
  # a unit that declares one, at that structure's top. Only a unit the plan
  # created changes type, and only to a type of that structure.
  def check_level!(map, current, level_id, parent_id)
    retyped = current && current.level_id != level_id
    refuse!("A unit's level can't change: create a unit at the new level instead") if retyped && org_unit?(map, current)
    returning = current && map.units.none? { it.id == current.id }
    moved = current && parent_id != current.parent_id
    return unless current.nil? || returning || moved || retyped

    parent = parent_on_map!(map, current, parent_id)
    structures = ::TeamPlanning::PlannedStructures.load(map)
    check_boundary!(map, structures, current, parent_id, retyped) if current
    taxonomy = structures.beneath(parent_id)
    kind = taxonomy.kind(current && !retyped ? structures.level_of(current) : level_id)
    refuse!(not_a_type(structures, level_id)) if (current.nil? || retyped) && !kind
    check_children!(map, structures, taxonomy, current, kind) if retyped
    return check_top!(kind) if parent.nil? || structures.declares?(parent_id)

    parent_kind = taxonomy.kind(structures.level_of(parent))
    refuse!("Level is no longer in the taxonomy, so the unit can't be placed") unless kind && parent_kind
    refuse!("#{kind.name} can't sit under #{parent_kind.name}") unless taxonomy.allows?(kind.id, beneath: parent_kind.id)
  end

  # Checked before any structure is read with it, so a parent the plan
  # doesn't cover gets the same refusal whatever structure it sits in.
  def parent_on_map!(map, current, parent_id)
    return unless parent_id

    parent = map.units.find { it.id == parent_id } || refuse!("The parent must be a live unit in this scenario")
    if current && ([ current.id ] + descendant_ids(map, current.id)).include?(parent_id)
      refuse!("A unit can't move beneath itself or a unit below it")
    end
    parent
  end

  # A unit the plan created never declares a structure, so its units sit in
  # the one it does and must still fit beneath its new type.
  def check_children!(map, structures, taxonomy, current, kind)
    map.units.select { it.parent_id == current.id }.each do |child|
      next unless (child_kind = taxonomy.kind(structures.level_of(child)))

      refuse!("#{child_kind.name} can't sit under #{kind.name}") unless taxonomy.allows?(child_kind.id, beneath: kind.id)
    end
  end

  # Crossing into another structure converts types, which only the Org Graph
  # does (step 10 plans it). A unit the plan created with nothing beneath it
  # may cross by taking a type of the structure it lands in, in the same call.
  def check_boundary!(map, structures, current, parent_id, retyped)
    return if structures.structure_at(current.id) == structures.structure_beneath(parent_id)
    return if retyped && (map.units + map.retired_units).none? { it.parent_id == current.id }

    refuse!("This move takes the unit into another structure, which a plan can't do yet. Move it in the Org Graph, " \
            "or create a unit of that structure's type instead")
  end

  # A type of a structure the plan can see, but not the one the unit would sit
  # in, is named as such; any other id reads as unknown.
  def not_a_type(structures, level_id)
    structures.visible_type?(level_id) ? "Level is not a type of the structure this unit would sit in" : "Level is not in the taxonomy"
  end

  def org_unit?(map, unit) = map.org_unit_levels.key?(unit.id)

  def check_top!(kind)
    refuse!("Level is no longer in the taxonomy, so the unit can't be placed") unless kind
    refuse!("#{kind.name} can't sit at the top") unless kind.top?
  end
end
