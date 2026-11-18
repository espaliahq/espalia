# frozen_string_literal: true

# What the Org Graph's Units view reads: the live unit tree, each unit's
# active members, and the active people in no live unit. Leaving ends no
# membership, so a leaver's rows stay; they count nowhere here.
#
# Loads the tenant's whole live structure in four queries and walks it in
# memory. A unit's headcount counts each person once across the unit and
# every unit beneath it, so someone in two squads of one team counts once
# for the team.
#
# A unit that declares a structure of its own (#494) gives the units beneath
# it that structure's types and rules, read here as the aggregate reads them.
#
# The page and {Operations::OrgGraph::Units} both read it, so the two agree.
class OrgGraph::UnitsOverview
  # @return [Array<OrgTaxonomyLevel>] the top structure's levels, top first
  attr_reader :levels

  # @return [Hash{String => Array<OrgTaxonomyLevel>}] each declared
  #   structure's levels, top first, by its declaring unit's id
  attr_reader :structures

  # @param selected_unit_id [String, nil] the unit to open; the first root
  #   unit when nil or not a live unit
  def initialize(selected_unit_id: nil)
    @levels = OrgTaxonomyLevel.top_structure.to_a
    @structures = OrgTaxonomyLevel.where.not(structure_unit_id: nil).order(:position).group_by(&:structure_unit_id)
    @units = OrgUnit.live.to_a.index_by(&:id)
    @children = @units.values.group_by { |unit| @units.key?(unit.parent_id) ? unit.parent_id : nil }
                      .transform_values { |units| units.sort_by(&:name) }
    @memberships = OrgMembership.where(unit_id: @units.keys).joins(:person).merge(Person.active)
                                .includes(:person).to_a.group_by(&:unit_id)
                                .transform_values { |list| list.sort_by { |membership| membership.person.name } }
    @selected_unit_id = selected_unit_id
  end

  # @return [Boolean]
  def any_units? = @units.any?

  # @return [Array<OrgUnit>] live units with no live parent, by name
  def roots = children_of(nil)

  # @param unit [OrgUnit, nil]
  # @return [Array<OrgUnit>] its live sub-units, by name
  def children_of(unit) = @children.fetch(unit&.id, [])

  # @param unit [OrgUnit]
  # @return [Array<OrgUnit>] every live unit beneath it, in tree order
  def descendants_of(unit)
    children_of(unit).flat_map { |child| [ child, *descendants_of(child) ] }
  end

  # @return [Array<OrgUnit>] every live unit, depth first, siblings by name:
  #   the order the tree shows them
  def in_tree_order
    roots.flat_map { |root| [ root, *descendants_of(root) ] }
  end

  # @return [OrgUnit, nil]
  def selected
    @units[@selected_unit_id] || roots.first
  end

  # @param unit [OrgUnit]
  # @return [Array<OrgUnit>] the units from the top down to this one
  def path_to(unit)
    path = [ unit ]
    path.unshift(@units[path.first.parent_id]) while path.first.parent_id && @units[path.first.parent_id]
    path
  end

  # @return [Array<OrgTaxonomyLevel>] every structure's levels, the top one's first
  def all_levels = @all_levels ||= [ *levels, *structures.values.flatten ]

  # @param unit [OrgUnit]
  # @return [OrgTaxonomyLevel, nil]
  def level_of(unit) = levels_by_id[unit.level_id]

  # @param unit [OrgUnit, nil]
  # @return [String, nil] the nearest unit strictly above it that declares a
  #   structure, nil where the top structure is in force
  def structure_unit_of(unit)
    above = unit && @units[unit.parent_id]
    above = @units[above.parent_id] until above.nil? || structures.key?(above.id)
    above&.id
  end

  # @param parent [OrgUnit, nil] nil for the root
  # @return [String, nil] the structure a unit placed beneath it answers to,
  #   nil for the top structure
  def structure_beneath(parent)
    return unless parent

    declares_structure?(parent) ? parent.id : structure_unit_of(parent)
  end

  # @param parent [OrgUnit, nil]
  # @return [String, nil] the kind a unit beneath it answers to; nil at the
  #   top of its structure, which is where a declaring unit's sub-units sit
  def seated_parent_kind(parent) = parent && !declares_structure?(parent) ? parent.level_id : nil

  # @param unit [OrgUnit, nil] nil for the top structure
  # @return [OrgGraph::Taxonomy] where each kind of unit may sit, in the
  #   structure in force at the unit
  def taxonomy(unit = nil) = taxonomy_of(structure_unit_of(unit))

  # @param structure_unit_id [String, nil] a declaring unit's id, nil for the top structure
  # @return [OrgGraph::Taxonomy]
  def taxonomy_of(structure_unit_id)
    @taxonomies ||= {}
    @taxonomies[structure_unit_id] ||= OrgTaxonomyLevel.taxonomy(structure_unit_id ? structures.fetch(structure_unit_id) : levels)
  end

  # @param unit [OrgUnit]
  # @return [Boolean] whether its own structure governs the units beneath it
  def declares_structure?(unit) = structures.key?(unit.id)

  # @param unit [OrgUnit]
  # @return [Integer] distinct people in the unit and every unit beneath it
  def headcount(unit) = people_within(unit).size

  # @param unit [OrgUnit]
  # @return [Array<OrgMembership>] the unit's own members, by name
  def members_of(unit) = @memberships.fetch(unit.id, [])

  # @param membership [OrgMembership]
  # @return [Array<OrgUnit>] the person's other live units, by name
  def other_units_of(membership)
    units_by_person.fetch(membership.person_id, []).reject { |unit| unit.id == membership.unit_id }
  end

  # The cards the selected unit opens to: itself when it has members of its
  # own or nothing beneath it, then each sub-unit.
  #
  # @return [Array<OrgUnit>]
  def cards
    return [] unless selected

    children = children_of(selected)
    own = members_of(selected).any? || children.empty? ? [ selected ] : []
    own + children
  end

  # @return [Array<Person>] active people in no live unit, by name
  def unplaced
    @unplaced ||= Person.active.in_no_unit.order(:name).to_a
  end

  private

  def levels_by_id = @levels_by_id ||= all_levels.index_by(&:id)

  def people_within(unit)
    @people_within ||= {}
    @people_within[unit.id] ||= children_of(unit).reduce(@memberships.fetch(unit.id, []).to_set(&:person_id)) do |ids, child|
      ids | people_within(child)
    end
  end

  def units_by_person
    @units_by_person ||= @memberships.values.flatten.group_by(&:person_id)
                                     .transform_values { |list| list.map { |m| @units[m.unit_id] }.sort_by(&:name) }
  end
end
