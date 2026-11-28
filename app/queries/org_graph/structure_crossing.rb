# frozen_string_literal: true

# Whether moving a unit beneath a parent takes it into another structure
# ([#510](https://github.com/espaliahq/espalia/issues/510)). It reads only the two units' live ancestors and which of them
# declare a structure, as {OrgGraph::UnitsOverview} does, and asks nothing
# about the caller's rights: the command checks those.
class OrgGraph::StructureCrossing
  # @param unit [OrgUnit] a live unit
  # @param parent_id [String, nil] the new parent, nil for the top
  def initialize(unit, parent_id)
    @unit = unit
    @parent_id = parent_id.presence
  end

  # @return [Boolean] false when the parent is not a live unit, so the move
  #   itself refuses it
  def crosses?
    return false if @parent_id && !parents.key?(@parent_id)

    structure_left != structure_joined
  end

  private

  def structure_left = declaring_above(@unit.id)

  def structure_joined
    return unless @parent_id

    declaring.include?(@parent_id) ? @parent_id : declaring_above(@parent_id)
  end

  def declaring_above(unit_id)
    above = parents[unit_id]
    above = parents[above] until above.nil? || declaring.include?(above)
    above
  end

  def declaring
    @declaring ||= OrgTaxonomyLevel.where(structure_unit_id: parents.keys).distinct.pluck(:structure_unit_id).to_set
  end

  # Each live unit on either chain, to its live parent. A retired parent ends
  # the chain, as it does in the Units view. The recursive UNION stops at a
  # unit already seen.
  def parents
    @parents ||= begin
      sql = <<~SQL.squish
        WITH RECURSIVE chain AS (
          SELECT id, parent_id FROM org_units
          WHERE id IN (:ids) AND tenant_id = :tenant_id AND retired_on IS NULL
          UNION
          SELECT u.id, u.parent_id FROM org_units u
          INNER JOIN chain ON u.id = chain.parent_id
          WHERE u.tenant_id = :tenant_id AND u.retired_on IS NULL
        )
        SELECT id, parent_id FROM chain
      SQL
      rows = OrgUnit.connection.select_rows(
        OrgUnit.sanitize_sql_array([ sql, { ids: [ @unit.id, @parent_id ].compact, tenant_id: @unit.tenant_id } ])
      )
      links = rows.to_h
      links.transform_values { links.key?(it) ? it : nil }
    end
  end
end
