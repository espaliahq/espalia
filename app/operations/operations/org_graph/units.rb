# frozen_string_literal: true

# The Units view's read (#80): the live unit tree, each unit's head count and
# member ids, and the active people in no live unit. Ids only, never names of
# people; an agent that needs a person looks them up.
class Operations::OrgGraph::Units < Operations::Base
  description "List the Org Graph's live units in tree order, the order the Units page shows them: each " \
              "with its id, name, level, parent, the provider that holds it (\"espalia\" or an HRIS), its " \
              "head count (distinct people in it and every unit beneath it) and the person ids of its own " \
              "members, and structure_unit_id, the unit whose own structure its type comes from (null for " \
              "the organisation's structure). Also returns the organisation's unit types, top first, each with the " \
              "type ids it can sit under (parent_ids) and whether it can sit at the top; the same for each " \
              "unit with a structure of its own (structures, by unit_id and name); and the ids of active people in no live " \
              "unit. Admins only while the Org Graph is unfinished."
  category :read
  approval :none

  def policy_check
    authorize :org_graph, :show_units?
  end

  # @return [Hash] levels, structures, units and the people in no unit
  def perform
    overview = ::OrgGraph::UnitsOverview.new
    unplaced = overview.unplaced.map(&:id)
    names = overview.in_tree_order.to_h { [ it.id, it.name ] }

    {
      levels: level_rows(overview.levels),
      structures: overview.structures.map { |unit_id, levels| { unit_id:, name: names[unit_id], levels: level_rows(levels) } },
      units: overview.in_tree_order.map { |unit| unit_payload(overview, unit) },
      in_no_unit: { count: unplaced.size, person_ids: unplaced }
    }
  end

  private

  def level_rows(levels)
    rules = OrgTaxonomyLevel.rules_by_id(levels)
    levels.map { |level| { id: level.id, name: level.name, **rules[level.id] } }
  end

  def unit_payload(overview, unit)
    {
      id: unit.id,
      name: unit.name,
      level_id: unit.level_id,
      parent_id: unit.parent_id,
      structure_unit_id: overview.structure_unit_of(unit),
      provider: unit.provider,
      headcount: overview.headcount(unit),
      member_ids: overview.members_of(unit).map(&:person_id)
    }
  end
end
