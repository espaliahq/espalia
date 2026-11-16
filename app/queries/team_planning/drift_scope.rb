# frozen_string_literal: true

# Cuts a scoped plan's drift to the people and units it covers
# ([#435](https://github.com/espaliahq/espalia/issues/435)). A scope hides
# the organisation's data about anything outside it, so a change about
# someone or some unit the plan doesn't cover at that point is dropped,
# names and all.
#
# Coverage follows the window in date order. Someone the baseline covers
# stops counting from the change that takes them out of the plan's units,
# and counts again if they come back. Someone the window brings in counts
# from that change on. Anyone a scenario holds that the baseline doesn't,
# and the plan's own units, count throughout, since the plan placed them.
#
# The change that takes someone or some unit out says so, but not where to,
# and the change that brings them in doesn't say where from: the other end
# is data about something outside. The same for a covered person now
# reporting to someone the plan can't name, and for the value a fact held
# before a change if it was set while they were outside. Each cut field is
# listed in `outside`.
class TeamPlanning::DriftScope
  PERSON_KINDS = %i[joined left fact_changed].freeze
  MEMBERSHIP_KINDS = %i[membership_started membership_ended membership_changed moved].freeze
  UNIT_KINDS = %i[unit_created unit_renamed unit_moved unit_retired owner_added owner_removed].freeze
  ENTERING = %i[membership_started moved].freeze

  # @!attribute change [OrgGraph::ChangesBetween::Change] with outside fields cut
  # @!attribute outside [Array<String>] the fields cut: "unit_id", "from_unit_id", "before", "after" or "person_id"
  Cut = Data.define(:change, :outside)

  # @param base [TeamPlanning::Baseline::Map] the plan's baseline
  # @param maps [Array<TeamPlanning::Baseline::Map>] each scenario's, the root's included
  def initialize(base, maps)
    based = held_people(base)
    @pinned = maps.flat_map { held_people(it).to_a }.to_set - based - base.outside_ids
    @unplaced = base.people.select { it.memberships.none?(&:unit_id) }.to_set(&:id)
    @placed = (base.people + base.outside).to_h { [ it.id, it.memberships.filter_map(&:unit_id).to_set ] }
    @placed.reject! { |id, _| @unplaced.include?(id) }
    @nameable = [ base, *maps ].flat_map(&:person_ids).to_set | based | @pinned
    @roots = Set.new(base.scope_ids) | (maps.flat_map { it.known_unit_ids.to_a }.to_set - base.known_unit_ids)
    @parents = [ base, *maps ].flat_map { it.units + it.retired_units }.to_h { [ it.id, it.parent_id ] }
    @unseen = Set.new
  end

  # @param changes [Array<OrgGraph::ChangesBetween::Change>] in date order
  # @return [Array<Cut>] the changes the plan covers when they happen, in the order given
  def call(changes)
    changes.filter_map do |change|
      cut(change).tap { advance(change) unless change.withdrawn }
    end
  end

  private

  def held_people(map) = map.people.to_set(&:id) | map.departed.to_set(&:person_id)

  def covered?(person_id)
    @pinned.include?(person_id) || @unplaced.include?(person_id) || Array(@placed[person_id]).any? { covered_unit?(it) }
  end

  def nameable?(person_id) = @nameable.include?(person_id) || covered?(person_id)

  def covered_unit?(unit_id)
    seen = Set.new
    while unit_id && seen.add?(unit_id)
      return true if @roots.include?(unit_id)

      unit_id = @parents[unit_id]
    end
    false
  end

  # Moves the window on past a change, so the next is judged as it happens.
  def advance(change)
    case change.kind
    when :joined then place(change.person_id) { Set.new(change.after&.dig("memberships")&.keys) }
    when :membership_started then place(change.person_id) { it << change.unit_id }
    when :membership_ended then place(change.person_id) { it.delete(change.unit_id) }
    when :moved then place(change.person_id) { it.delete(change.from_unit_id) << change.unit_id }
    when :unit_created, :unit_moved then @parents[change.unit_id] = change.after&.dig("parent_id")
    end
  end

  def place(person_id)
    @unplaced.delete(person_id)
    @placed[person_id] = yield(@placed.fetch(person_id, Set.new).dup).delete(nil)
  end

  def cut(change)
    case change.kind
    when *PERSON_KINDS then person(change)
    when *MEMBERSHIP_KINDS then membership(change)
    when *UNIT_KINDS then unit(change)
    when :unit_succeeded then succession(change)
    end
  end

  def person(change)
    return unseen(change, change.person_id) unless covered?(change.person_id) || joins_covered?(change)
    return Cut.new(change: change.with(before: nil), outside: [ "before" ]) if seen?(change, change.person_id)
    return Cut.new(change:, outside: []) unless change.fact == "manager"

    fields = %w[before after].select { (id = change.public_send(it)&.dig("manager_id")) && !nameable?(id) }
    Cut.new(change: change.with(**fields.to_h { [ it.to_sym, change.public_send(it).merge("manager_id" => nil) ] }), outside: fields)
  end

  # A fact or name set while its subject was outside the plan is data about
  # something outside, so the next change to it once covered drops it as `before`.
  def unseen(change, subject_id)
    @unseen << [ subject_id, change.kind, change.fact ] unless change.withdrawn
    nil
  end

  def seen?(change, subject_id) = !!@unseen.delete?([ subject_id, change.kind, change.fact ])

  def joins_covered?(change)
    change.kind == :joined && Array(change.after&.dig("memberships")&.keys).any? { covered_unit?(it) }
  end

  def membership(change)
    return unless covered?(change.person_id) || (ENTERING.include?(change.kind) && covered_unit?(change.unit_id))

    fields = %w[unit_id from_unit_id].select { (id = change.public_send(it)) && !covered_unit?(id) }
    return if fields.include?("unit_id") && (change.kind != :moved || fields.include?("from_unit_id"))

    Cut.new(change: change.with(**fields.to_h { [ it.to_sym, nil ] }), outside: fields)
  end

  def unit(change)
    entering = %i[unit_created unit_moved].include?(change.kind) && covered_unit?(change.after&.dig("parent_id"))
    return unseen(change, change.unit_id) unless covered_unit?(change.unit_id) || entering

    case change.kind
    when :unit_renamed
      seen?(change, change.unit_id) ? Cut.new(change: change.with(before: nil), outside: [ "before" ]) : Cut.new(change:, outside: [])
    when :unit_moved
      fields = %w[before after].select { (id = change.public_send(it)&.dig("parent_id")) && !covered_unit?(id) }
      Cut.new(change: change.with(**fields.to_h { [ it.to_sym, change.public_send(it).merge("parent_id" => nil) ] }), outside: fields)
    when :unit_retired
      after = change.after&.merge("successor_ids" => Array(change.after["successor_ids"]).select { covered_unit?(it) })
      Cut.new(change: change.with(after:), outside: after == change.after ? [] : [ "after" ])
    when :owner_added, :owner_removed
      nameable?(change.person_id) ? Cut.new(change:, outside: []) : Cut.new(change: change.with(person_id: nil), outside: [ "person_id" ])
    else Cut.new(change:, outside: [])
    end
  end

  def succession(change)
    ids = %w[before after].flat_map { |side| %w[predecessor_ids successor_ids].flat_map { Array(change.public_send(side)&.dig(it)) } }
    return unless ids.any? { covered_unit?(it) }

    cuts = %w[before after].filter_map do |side|
      fields = change.public_send(side)
      next unless fields

      kept = fields.to_h { |key, value| [ key, key.end_with?("_ids") ? Array(value).select { covered_unit?(it) } : value ] }
      [ side, kept ] unless kept == fields
    end
    Cut.new(change: change.with(**cuts.to_h { [ it.first.to_sym, it.last ] }), outside: cuts.map(&:first))
  end
end
