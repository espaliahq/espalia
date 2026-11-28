# frozen_string_literal: true

# The units a person has rights over as an owner, or as someone an owner
# reports to: every unit owned by an active person in their subtree, and
# every unit beneath those. A manager in between who has left doesn't break
# the line, since {Person#all_reports} walks through them.
#
# Built once per policy. A request reads it once; a command handler builds a
# policy for each check, so a check under the structure's lock, or of a unit
# the command just created, reads the line as it stands. Both queries name the
# person's tenant, so neither leans on a current tenant being set.
#
# @example
#   OrgGraphPolicy::Reach.new(person).covers?(unit)
class OrgGraphPolicy::Reach
  # @param person [Person, nil] nil, or someone who has left, reaches nothing
  def initialize(person)
    @person = person&.status == "active" ? person : nil
  end

  # @param unit [OrgUnit, nil]
  # @return [Boolean] whether the unit, or a unit above it, is owned within reach
  def covers?(unit)
    unit.present? && covered_unit_ids.include?(unit.id)
  end

  # A retired unit keeps its owners, but gives them nothing to reach.
  #
  # @return [Set<String>] the live units owned by active people in the subtree
  def owned_unit_ids
    @owned_unit_ids ||= if @person
      subtree = [ @person.id, *@person.all_reports.pluck(:id) ]
      OrgUnitOwner.joins(:person, :unit).merge(Person.active).merge(OrgUnit.live)
                  .where(tenant_id: @person.tenant_id, person_id: subtree).distinct.pluck(:unit_id).to_set
    else
      Set.new
    end
  end

  private

  def covered_unit_ids
    @covered_unit_ids ||= owned_unit_ids.empty? ? Set.new : descendants_and_self(owned_unit_ids)
  end

  def descendants_and_self(unit_ids)
    sql = <<~SQL.squish
      WITH RECURSIVE covered AS (
        SELECT id FROM org_units WHERE id IN (:unit_ids) AND tenant_id = :tenant_id
        UNION
        SELECT u.id FROM org_units u INNER JOIN covered c ON u.parent_id = c.id
        WHERE u.tenant_id = :tenant_id
      )
      SELECT id FROM covered
    SQL
    OrgUnit.connection.select_values(
      OrgUnit.sanitize_sql_array([ sql, { unit_ids: unit_ids.to_a, tenant_id: @person.tenant_id } ])
    ).to_set
  end
end
