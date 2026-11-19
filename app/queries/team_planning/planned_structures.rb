# frozen_string_literal: true

# The structure in force at each unit of a resolved scenario
# ([#494](https://github.com/espaliahq/espalia/issues/494)). A unit
# that declares its own structure governs the units beneath it, so a unit's
# types and rules come from the nearest declaring unit above it, along the
# scenario's planned parents. A unit the plan created never declares one.
#
# The structures are the Org Graph's as they stand today, as every other
# check a plan makes reads today's taxonomy: a declaration after the plan's
# base is drift, and the plan is judged against it.
#
# For the same reason an Org Graph unit holds its type as it stands today,
# which a declaration may have converted since the base; a unit the plan
# created holds the one it was given.
#
# Above a scoped plan's roots the walk reads the Org Graph's live parents,
# units the plan doesn't cover. Nothing from that walk leaves this class but
# a type: a caller never learns which unit declared it.
#
# @example
#   structures = TeamPlanning::PlannedStructures.load(map)
#   structures.beneath(parent_id).kind(level_id)
class TeamPlanning::PlannedStructures
  EMPTY = OrgGraph::Taxonomy.new([])

  # @param map [TeamPlanning::Baseline::Map]
  # @return [TeamPlanning::PlannedStructures]
  def self.load(map)
    rows = OrgTaxonomyLevel.order(:position).to_a.group_by(&:structure_unit_id)
    live = OrgUnit.pluck(:id, :parent_id, :level_id)
    new(map, taxonomies: rows.transform_values { OrgTaxonomyLevel.taxonomy(it) },
             copies: rows.transform_values { |levels| levels.select(&:copied_from_level_id).to_h { [ it.copied_from_level_id, it.id ] } },
             live_parents: live.to_h { |id, parent_id, _| [ id, parent_id ] }, live_levels: live.to_h { |id, _, level_id| [ id, level_id ] })
  end

  # @param map [TeamPlanning::Baseline::Map]
  # @param taxonomies [Hash{String, nil => OrgGraph::Taxonomy}] each structure, by declaring unit id; nil for the top
  # @param copies [Hash{String, nil => Hash{String => String}}] each structure's copied types, source type id => its copy's id
  # @param live_parents [Hash{String => String, nil}] every Org Graph unit's live parent
  # @param live_levels [Hash{String => String}] every Org Graph unit's live type
  def initialize(map, taxonomies:, copies: {}, live_parents: {}, live_levels: {})
    @taxonomies = taxonomies
    @copies = copies
    @live_parents = live_parents
    @live_levels = live_levels
    @planned = (map.units + map.retired_units).index_by(&:id)
  end

  # @param unit_id [String] a unit on the map
  # @return [String, nil] the declaring unit whose structure is in force at it; nil for the top structure
  def structure_at(unit_id)
    @at ||= {}
    @at.fetch(unit_id) { @at[unit_id] = nearest_declaring_above(unit_id) }
  end

  # @param unit [TeamPlanning::Baseline::Unit] a unit on the map
  # @return [String] its type: the live one for an Org Graph unit
  def level_of(unit) = @live_levels.fetch(unit.id) { unit.level_id }

  # @param parent_id [String, nil] nil for the top
  # @return [String, nil] the structure a unit placed beneath the parent sits in
  def structure_beneath(parent_id)
    return unless parent_id

    declares?(parent_id) ? parent_id : structure_at(parent_id)
  end

  # @param parent_id [String, nil]
  # @return [OrgGraph::Taxonomy] the types a unit beneath the parent may take
  def beneath(parent_id) = taxonomy_of(structure_beneath(parent_id))

  # @param unit_id [String]
  # @return [OrgGraph::Taxonomy] the types of the structure in force at the unit
  def at(unit_id) = taxonomy_of(structure_at(unit_id))

  # @param unit_id [String]
  # @return [Boolean] whether the unit governs the units beneath it, so they
  #   sit at the top of its structure
  def declares?(unit_id) = !unit_id.nil? && @taxonomies.key?(unit_id)

  # @param structure_unit_id [String, nil]
  # @return [OrgGraph::Taxonomy] empty for a top structure with no types
  def taxonomy_of(structure_unit_id) = @taxonomies.fetch(structure_unit_id) { EMPTY }

  # @param level_id [String] a type of another structure
  # @param unit_id [String]
  # @return [OrgGraph::Taxonomy::Kind, nil] the type the structure in force at the unit copied from it
  def copy_at(level_id, unit_id)
    structure = structure_at(unit_id)
    at(unit_id).kind(@copies.dig(structure, level_id))
  end

  # @param level_id [String, nil]
  # @return [Boolean] whether the type belongs to a structure in force at a
  #   unit on the map, or declared by one, so the plan may name it
  def visible_type?(level_id) = visible.any? { taxonomy_of(it).kind(level_id) }

  private

  def nearest_declaring_above(unit_id)
    seen = Set[unit_id]
    above = parent_of(unit_id)
    while above && seen.add?(above)
      return above if declares?(above)

      above = parent_of(above)
    end
  end

  # A unit on the map sits where the scenario puts it; above the map, where
  # the Org Graph has it today.
  def parent_of(unit_id) = @planned.key?(unit_id) ? @planned[unit_id].parent_id : @live_parents[unit_id]

  # nil, the top structure, is visible when some unit on the map sits in it.
  def visible = @visible ||= @planned.keys.flat_map { [ structure_at(it), *(it if declares?(it)) ] }.to_set
end
