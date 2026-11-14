# frozen_string_literal: true

# How the map reads show a resolved organisation: people by id, each with
# their places and allocation total, positions with their occupants and open
# FTE, and a `names` entry for every person id the payload uses, so a client
# never meets an id it can't name.
module Operations::TeamPlanning::MapPayload
  private

  # @param map [TeamPlanning::Baseline::Map] with names joined
  # @return [Hash] `{ base_on, known_on, units, people, unassigned_ids, positions, unresolved, names }`
  def map_payload(map)
    { base_on: map.base_on.iso8601, known_on: map.known_on.iso8601,
      units: map.units.map(&:to_h),
      people: people_payload(map),
      unassigned_ids: map.unassigned_ids,
      positions: positions_payload(map),
      unresolved: map.unresolved.map(&:to_h),
      names: names_for(map) }
  end

  def people_payload(map)
    totals = map.allocation_totals
    map.people.map { it.to_h.merge(memberships: it.memberships.map(&:to_h), allocation_total: totals[it.id]) }
  end

  def positions_payload(map)
    by_position = map.occupants
    map.positions.map do |position|
      held = by_position.fetch(position.id, [])
      occupants = held.map { |person, place| { person_id: person.id, allocation: place.allocation, role: place.role } }
      { position_id: position.id, **position.to_h.except(:id), budget: position.budget, occupants:, open_fte: map.open_fte(position, held) }
    end
  end

  def names_for(map) = map.person_ids.to_h { [ it, map.name_of(it) ] }
end
