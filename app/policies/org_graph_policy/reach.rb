# frozen_string_literal: true

# The units a person stands over: every unit owned by them or by anyone below
# them on `people.manager_id`, and every unit beneath those. The line is read
# as it stands now, at any depth. Only owners still working here count; a
# manager in between who has left does not break the line.
#
# Two queries build it, whatever the tree's size: the person's reports and
# the units their subtree owns. An ancestor walk reads the units given to
# {#index}, and loads the rest of a unit's ancestors in one query.
#
# @example
#   reach = OrgGraphPolicy::Reach.new(person).index(overview.in_tree_order)
#   reach.covers?(unit)
class OrgGraphPolicy::Reach
  # @param person [Person, nil] the caller; nil, or someone who has left, reaches nothing
  def initialize(person)
    @person = person
    @units = {}
  end

  # Remembers these units, so walks from them stay in memory.
  #
  # @param units [Enumerable<OrgUnit>]
  # @return [self]
  def index(units)
    units.each { |unit| @units[unit.id] ||= unit }
    self
  end

  # @param unit [OrgUnit, nil]
  # @return [Boolean] whether someone in the person's subtree owns the unit or a unit above it
  def covers?(unit)
    return false if unit.nil? || owned_unit_ids.empty?

    lineage(unit).any? { |link| owned_unit_ids.include?(link.id) }
  end

  # @return [Set<String>] the units the person, or anyone below them, owns
  def owned_unit_ids
    @owned_unit_ids ||= if @person&.status == "active"
                          subtree = [ @person.id, *@person.all_reports.ids ]
                          OrgUnitOwner.where(person_id: Person.active.where(id: subtree).select(:id)).distinct.pluck(:unit_id).to_set
    else
                          Set.new
    end
  end

  # The unit and every unit above it, nearest first. A cycle in the parents
  # ends the walk.
  #
  # @param unit [OrgUnit]
  # @return [Array<OrgUnit>]
  def lineage(unit)
    @units[unit.id] ||= unit
    path = walk(unit)
    return path unless path.last.parent_id && !@units.key?(path.last.parent_id)

    load_ancestors(unit)
    walk(unit)
  end

  private

  def walk(unit)
    path = []
    while unit && path.none? { it.id == unit.id }
      path << unit
      unit = unit.parent_id && @units[unit.parent_id]
    end
    path
  end

  def load_ancestors(unit)
    sql = <<~SQL.squish
      WITH RECURSIVE ancestors AS (
        SELECT id, parent_id FROM org_units WHERE id = :id AND tenant_id = :tenant_id
        UNION
        SELECT u.id, u.parent_id FROM org_units u
        INNER JOIN ancestors a ON u.id = a.parent_id
        WHERE u.tenant_id = :tenant_id
      )
      SELECT id FROM ancestors
    SQL
    ids = OrgUnit.connection.select_values(OrgUnit.sanitize_sql_array([ sql, { id: unit.id, tenant_id: unit.tenant_id } ]))
    index(OrgUnit.where(id: ids - @units.keys))
  end
end
