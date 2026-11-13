# frozen_string_literal: true

# The Units view's read (#80): the live unit tree, each unit's head count and
# member ids, and the active people in no live unit. Ids only, never names of
# people; an agent that needs a person looks them up.
class Operations::OrgGraph::Units < Operations::Base
  description "List the Org Graph's live units in tree order, the order the Units page shows them: each " \
              "with its id, name, level, parent, the provider that holds it (\"espalia\" or an HRIS), its " \
              "head count (distinct people in it and every unit beneath it) and the person ids of its own " \
              "members. Also returns the taxonomy levels, top first, and the ids of active people in no live " \
              "unit. Admins only while the Org Graph is unfinished."
  category :read
  approval :none

  def policy_check
    authorize :org_graph, :show_units?
  end

  # @return [Hash] levels, units and the people in no unit
  def perform
    overview = ::OrgGraph::UnitsOverview.new
    unplaced = overview.unplaced.map(&:id)

    {
      levels: overview.levels.map { |level| { id: level.id, name: level.name } },
      units: overview.in_tree_order.map { |unit| unit_payload(overview, unit) },
      in_no_unit: { count: unplaced.size, person_ids: unplaced }
    }
  end

  private

  def unit_payload(overview, unit)
    {
      id: unit.id,
      name: unit.name,
      level_id: unit.level_id,
      parent_id: unit.parent_id,
      provider: unit.provider,
      headcount: overview.headcount(unit),
      member_ids: overview.members_of(unit).map(&:person_id)
    }
  end
end
