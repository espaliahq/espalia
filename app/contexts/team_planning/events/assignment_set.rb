# frozen_string_literal: true

# Every place a person holds in a scenario, set at once: a list of
# placements, each in a position or a unit, with an allocation. The last one
# wins, so a move never leaves a person half in the old place and half in the
# new. An empty list leaves the person unassigned.
#
# A placement in a position takes the position's unit when the map settles,
# so moving a position moves its people. A person the map doesn't have, such
# as a new starter after the base date, is never placed, but never silently:
# the map lists them as unresolved.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :subject_id the person's id
#   @option data [Array<Hash>] :placements each with `position_id` or `unit_id` (the other nil),
#     an `allocation` above 0 and at most 1, or nil when the Org Graph gives none, and a `role`,
#     nil when none is named
#   Plus {TeamPlanning::Events::Change::FIELDS}.
#
class TeamPlanning::Events::AssignmentSet < TeamPlanning::Events::Change
  about_a_person

  PLACES = %i[position_id unit_id].freeze
  MOVED_BY = %i[membership_started membership_ended membership_changed moved].freeze

  # @return [String]
  def self.facet = "assignment"

  # @param data [Hash]
  # @return [Array<String>] the positions and units it places the person in
  def self.refers_to(data) = Array(data[:placements]).flat_map { it.to_h.with_indifferent_access.values_at(*PLACES) }.compact

  # @param end_state [Hash] `{ placements: [{ position_id or unit_id, allocation, role }] }`
  # @return [Hash] the ids downcased, each allocation a Float
  # @raise [TeamPlanning::Error] for a placement in both a position and a unit, or neither, an
  #   allocation outside (0, 1], or a place held twice. A total over 1 is never refused, and a nil
  #   allocation, unknown as the Org Graph can hold it, is kept as nil.
  def self.end_state(end_state)
    placements = end_state[:placements]
    raise TeamPlanning::Error, "An assignment lists its placements, or none to leave the person unassigned" unless placements.is_a?(Array)

    placements = placements.map { placement!(it) }
    raise TeamPlanning::Error, "A person holds each position and unit once" if placements.map { it.slice(*PLACES) }.uniq.size < placements.size

    { placements: }
  end

  # @param map [TeamPlanning::Baseline::Map]
  # @param subject_id [String]
  # @return [Hash, nil] the person's placements in the shape {.end_state} gives, nil when the map hasn't them
  def self.read_from(map, subject_id:, facet: self.facet)
    person = map.people.find { it.id == subject_id }
    { placements: person.memberships.map { placement_of(it) } } if person
  end

  # A settled map gives a position placement its position's unit; the placement names only the position.
  def self.placement_of(membership)
    placement = membership.to_h.slice(*PLACES, :allocation, :role)
    placement[:position_id] ? placement.merge(unit_id: nil) : placement
  end

  # A person holds each place once, so two lists in another order are the same placements.
  #
  # @param left [Hash, nil]
  # @param right [Hash, nil]
  # @return [Boolean]
  def self.same_end_state?(left, right) = super(in_order(left), in_order(right))

  # The Org Graph can't say which position someone fills, only where they are, so a placement in
  # a position shows as a place in the position's unit on the plan's map, at its allocation, with
  # its role only when the plan names one.
  #
  # @param read [Hash, nil] the placements read off the Org Graph
  # @param planned [Hash, nil]
  # @param map [TeamPlanning::Baseline::Map] settled, so each position has its unit
  # @return [Boolean]
  def self.shows?(read, planned, map:)
    return same_end_state?(read, planned) unless read && planned

    units = map.position_units
    places = read.as_json.fetch("placements").dup
    wanted = planned.as_json.fetch("placements")
    return false unless wanted.size == places.size

    wanted.all? do |want|
      index = places.index { shows_place?(it, want, units) }
      index && places.delete_at(index)
    end
  end

  # @param change [OrgGraph::ChangesBetween::Change]
  # @return [String, nil] the person an Org Graph change places, moves or takes out of a unit
  def self.subject_moved_by(change) = (change.person_id if MOVED_BY.include?(change.kind))

  def self.in_order(end_state)
    return end_state unless end_state

    placements = end_state.as_json.fetch("placements")
    { "placements" => placements.sort_by { [ it["unit_id"].to_s, it["position_id"].to_s ] } }
  end

  # @param map [TeamPlanning::Baseline::Map]
  # @param data [Hash]
  # @return [TeamPlanning::Baseline::Map] for a person the map doesn't have, the placement
  #   waits in `unresolved`, its reason given when the resolution settles
  def self.apply_to(map, data)
    unless map.holds?(data[:subject_id])
      return map if data[:placements].empty?

      return map.with(unresolved: map.unresolved + [ TeamPlanning::Baseline::Unresolved.new(person_id: data[:subject_id], why: nil) ])
    end

    memberships = data[:placements].map { TeamPlanning::Baseline::Membership.new(**it.to_h.symbolize_keys.slice(*TeamPlanning::Baseline::Membership.members)) }
    map.updating(data[:subject_id]) { it.with(memberships:) }
  end

  def self.shows_place?(place, wanted, units)
    return place == wanted unless wanted["position_id"]

    place["unit_id"] == units[wanted["position_id"]] && !place["unit_id"].nil? && place["allocation"] == wanted["allocation"] &&
      (wanted["role"].nil? || place["role"] == wanted["role"])
  end

  def self.placement!(placement)
    raise TeamPlanning::Error, "A placement names a position or a unit" unless placement.is_a?(Hash)

    placement = placement.symbolize_keys
    places = PLACES.to_h { [ it, placement[it].to_s.strip.downcase.presence ] }
    raise TeamPlanning::Error, "A placement is in a position or a unit, not both" if places.values.all?
    raise TeamPlanning::Error, "A placement names a position or a unit" if places.values.none?

    { **places, allocation: allocation!(placement[:allocation]), role: placement[:role].to_s.strip.presence }
  end

  def self.allocation!(value)
    return nil if value.nil?

    allocation = Float(value, exception: false)
    return allocation if allocation&.positive? && allocation <= 1

    raise TeamPlanning::Error, "An allocation is above 0 and at most 1"
  end

  private_class_method :placement!, :allocation!, :in_order, :placement_of, :shows_place?
end
