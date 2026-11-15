# frozen_string_literal: true

# How the map reads show a resolved organisation. People come by id, with
# their places, allocation total, reporting line and whether they are
# leaving. Positions carry their occupants, open FTE and whom they backfill,
# and `departed` lists those a departure took off the map. Every person id
# has a `names` entry, so a client never meets an id it can't name, and a
# placeholder hire's name is its label.
#
# What the plan holds privately reads as `{ value: }`, or `{ removed: true }`
# once its key is gone, under `planned_level`, `plan_data` and `placeholder`.
#
# A plan with a scope never shows anyone or anything outside it
# [#338](https://github.com/espaliahq/espalia/issues/338). A person keeps only
# their places in it, with `outside: { share: }` for the rest of their time; a
# manager outside reads as `manager_outside: true`, and a covered unit's parent
# or owner outside is left out. A plan covering the whole organisation reads as
# it always has.
module Operations::TeamPlanning::MapPayload
  # @param value [Shreddable::Value, nil]
  # @return [Hash, nil] `{ value: }`, or `{ removed: true }` once its key is gone
  def self.sealed(value)
    return nil if value.nil?

    value.removed? ? { removed: true } : { value: value.reveal }
  end

  private

  # @param map [TeamPlanning::Baseline::Map] with names joined
  # @return [Hash] `{ base_on, known_on, units, people, unassigned_ids, positions, unresolved, departed, names }`
  def map_payload(map)
    { base_on: map.base_on.iso8601, known_on: map.known_on.iso8601,
      units: units_payload(map),
      people: people_payload(map),
      unassigned_ids: map.unassigned_ids,
      positions: positions_payload(map),
      unresolved: map.unresolved.map(&:to_h),
      departed: map.departed.map { it.departure.except(:leaves_in_id).merge(person_id: it.person_id) },
      names: names_for(map) }
  end

  def units_payload(map)
    return map.units.map(&:to_h) unless map.scope_ids

    on_map = map.units.to_set(&:id)
    map.units.map do |unit|
      unit.to_h.merge(parent_id: (unit.parent_id if on_map.include?(unit.parent_id)), owner_ids: unit.owner_ids.reject { map.outside?(it) })
    end
  end

  def people_payload(map)
    totals = map.allocation_totals
    map.people.map do |person|
      payload = person.to_h.except(:departure, :planned_level, :plan_data, :placeholder, :capacity_overrides)
                      .merge(planned_level: sealed_payload(person.planned_level), plan_data: person.plan_data.transform_values { sealed_payload(it) },
                             capacity_overrides: person.capacity_overrides.transform_values { sealed_payload(it) },
                             placeholder: sealed_payload(person.placeholder), memberships: person.memberships.map(&:to_h), allocation_total: totals[person.id],
                             leaving: person.leaving?, leaves_on: (person.departure[:leaves_on] if person.leaving?), backfill_position_id: person.backfill_id)
      map.scope_ids ? within_scope(payload, person, map) : payload
    end
  end

  def within_scope(payload, person, map)
    away = map.outside_places(person)
    share = ::TeamPlanning::Baseline::Membership.shares(person.memberships).sum(0r) { |place, part, _| away.include?(place) ? part : 0r }
    manager_outside = map.outside?(person.manager_id)
    payload.merge(memberships: (person.memberships - away).map(&:to_h), outside: (away.any? ? { share: share.to_f } : nil),
                  manager_id: (person.manager_id unless manager_outside), manager_outside:)
  end

  def positions_payload(map)
    by_position = map.occupants
    backfills = map.backfills
    map.positions.map do |position|
      held = by_position.fetch(position.id, [])
      occupants = held.map { |person, place| { person_id: person.id, allocation: place.allocation, role: place.role } }
      { position_id: position.id, **position.to_h.except(:id), budget: position.budget, occupants:, open_fte: map.open_fte(position, held),
        backfill_for_ids: backfills.fetch(position.id, []) }
    end
  end

  def names_for(map) = map.person_ids.index_with { map.name_of(it) }

  def sealed_payload(value) = Operations::TeamPlanning::MapPayload.sealed(value)
end
