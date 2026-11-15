# frozen_string_literal: true

# Someone a scenario has leaving, and the position that backfills them. In
# the step that sets it, and its alternatives, they stay on the map marked as
# leaving, and never count as filling their backfill. In the steps after it
# they are gone and the position stands alone. The link lives only here, so
# undoing or clearing the departure drops it.
#
# A leaving date within the step says when in it they go, so cost can split
# the step between them and their backfill. Without one, the step is the
# date: they cost nothing in it, and the backfill carries the whole seat.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :subject_id the person's id
#   @option data [String, nil] :position_id the backfill; nil when the seat isn't backfilled
#   @option data [String] :leaves_in_id the scenario whose step they leave in, so a pin in a
#     later step keeps them gone
#   @option data [String] :leaves_on an ISO date within that step; absent when the step is the date
#   Plus {TeamPlanning::Events::Change::FIELDS}.
#
class TeamPlanning::Events::DepartureSet < TeamPlanning::Events::Change
  about_a_person

  # @return [String]
  def self.facet = "departure"

  # @param end_state [Hash] `{ leaves_in_id:, position_id:, leaves_on: }`, the position nil or absent
  #   for no backfill, the date absent when the step is the date
  # @return [Hash] the ids downcased, and `leaves_on` only when given
  # @raise [TeamPlanning::Error] without the step they leave in, or with a date that isn't one
  def self.end_state(end_state)
    leaves_in_id = end_state[:leaves_in_id].to_s.strip.downcase.presence
    raise TeamPlanning::Error, "A departure names the step the person leaves in" unless leaves_in_id

    state = { leaves_in_id:, position_id: end_state[:position_id].to_s.strip.downcase.presence }
    leaves_on = leaving_date(end_state[:leaves_on])
    leaves_on ? state.merge(leaves_on: leaves_on.iso8601) : state
  end

  # @param value [Date, String, nil]
  # @return [Date, nil]
  # @raise [TeamPlanning::Error] for anything but an ISO date
  def self.leaving_date(value)
    return value if value.is_a?(Date)
    return nil if value.to_s.strip.empty?

    Date.iso8601(value.to_s.strip)
  rescue Date::Error
    raise TeamPlanning::Error, "A leaving date must be a date, such as 2027-03-31"
  end

  # @param map [TeamPlanning::Baseline::Map]
  # @param data [Hash]
  # @return [TeamPlanning::Baseline::Map] the person marked; {TeamPlanning::Baseline::Map#settled}
  #   takes them off when the departure was set in an earlier step
  def self.apply_to(map, data)
    unless map.holds?(data[:subject_id])
      return map.with(unresolved: map.unresolved + [ TeamPlanning::Baseline::Unresolved.new(person_id: data[:subject_id], why: nil) ])
    end

    departure = data.slice(:leaves_in_id, :position_id, :leaves_on)
    map.updating(data[:subject_id]) { it.with(departure:) }
  end

  # @param map [TeamPlanning::Baseline::Map]
  # @param subject_id [String]
  # @param facet [String]
  # @return [Hash, nil] the departure, nil when the map has none for the person
  def self.read_from(map, subject_id:, facet: self.facet)
    map.people.find { it.id == subject_id }&.departure ||
      map.departed.find { it.person_id == subject_id }&.departure
  end

  # @param change [OrgGraph::ChangesBetween::Change]
  # @return [String, nil] the person, when the Org Graph has them leave
  def self.subject_moved_by(change) = (change.person_id if change.kind == :left)

  # The Org Graph knows only that someone left, not the step or the backfill,
  # so a leaver reads as the plan has them leave.
  #
  # @param map [TeamPlanning::Baseline::Map] read off the Org Graph
  # @param change [TeamPlanning::Events::DepartureSet]
  # @return [Hash, nil] the planned departure once the person has left, nil while they stay
  def self.read_org_graph(map, change)
    change.data.except(*FIELDS) if map.left_ids.include?(change.data[:subject_id])
  end
end
