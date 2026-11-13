# frozen_string_literal: true

# What the Org Graph's Units view reads: the live unit tree, each unit's
# members, and the active people in no live unit.
#
# Loads the tenant's whole live structure in four queries and walks it in
# memory. A unit's headcount counts each person once across the unit and
# every unit beneath it, so someone in two squads of one team counts once
# for the team.
#
# Web-only for now: the Org Graph is unfinished, and its read for MCP waits
# for "as known on" (story 3.2), which changes what it returns.
class OrgGraph::UnitsOverview
  # @return [Array<OrgTaxonomyLevel>] top level first
  attr_reader :levels

  # @param selected_unit_id [String, nil] the unit to open; the first root
  #   unit when nil or not a live unit
  def initialize(selected_unit_id: nil)
    @levels = OrgTaxonomyLevel.top_first.to_a
    @units = OrgUnit.live.to_a.index_by(&:id)
    @children = @units.values.group_by(&:parent_id).transform_values { |units| units.sort_by(&:name) }
    @memberships = OrgMembership.in_live_units.includes(:person).to_a.group_by(&:unit_id)
    @selected_unit_id = selected_unit_id
  end

  # @return [Boolean]
  def any_units? = @units.any?

  # @return [Array<OrgUnit>] live units with no parent, by name
  def roots = children_of(nil)

  # @param unit [OrgUnit, nil]
  # @return [Array<OrgUnit>] its live sub-units, by name
  def children_of(unit) = @children.fetch(unit&.id, [])

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

  # @param unit [OrgUnit]
  # @return [OrgTaxonomyLevel, nil]
  def level_of(unit) = levels.find { |level| level.id == unit.level_id }

  # @param unit [OrgUnit]
  # @return [Integer] distinct people in the unit and every unit beneath it
  def headcount(unit)
    @headcounts ||= {}
    @headcounts[unit.id] ||= people_within(unit).size
  end

  # @param unit [OrgUnit]
  # @return [Array<OrgMembership>] the unit's own members, by name
  def members_of(unit)
    @memberships.fetch(unit.id, []).select(&:person).sort_by { |membership| membership.person.name }
  end

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

  # @return [ActiveRecord::Relation<Person>] active people in no live unit, by name
  def unplaced
    @unplaced ||= Person.active.in_no_unit.order(:name)
  end

  private

  def people_within(unit)
    ids = @memberships.fetch(unit.id, []).map(&:person_id)
    children_of(unit).each { |child| ids.concat(people_within(child).to_a) }
    ids.to_set
  end

  def units_by_person
    @units_by_person ||= @memberships.values.flatten.group_by(&:person_id)
                                     .transform_values { |list| list.map { |m| @units[m.unit_id] }.sort_by(&:name) }
  end
end
