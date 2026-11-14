# frozen_string_literal: true

# Someone a scenario has leaving, and the position that backfills them. In
# the step that sets it, and its alternatives, they stay on the map marked as
# leaving, and never count as filling their backfill. In the steps after it
# they are gone and the position stands alone. The link lives only here, so
# undoing or clearing the departure drops it.
#
# The step is the date for now. Costing part of a period (5.4) will need an
# optional leaving date within the step.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :subject_id the person's id
#   @option data [String, nil] :position_id the backfill; nil when the seat isn't backfilled
#   @option data [String] :leaves_in_id the scenario whose step they leave in, so a pin in a
#     later step keeps them gone
#   Plus {TeamPlanning::Events::Change::FIELDS}.
#
class TeamPlanning::Events::DepartureSet < TeamPlanning::Events::Change
  # @return [String]
  def self.facet = "departure"

  # @param end_state [Hash] `{ leaves_in_id:, position_id: }`, the position nil or absent for no backfill
  # @return [Hash] the ids downcased
  # @raise [TeamPlanning::Error] without the step they leave in
  def self.end_state(end_state)
    leaves_in_id = end_state[:leaves_in_id].to_s.strip.downcase.presence
    raise TeamPlanning::Error, "A departure names the step the person leaves in" unless leaves_in_id

    { leaves_in_id:, position_id: end_state[:position_id].to_s.strip.downcase.presence }
  end

  # @param map [TeamPlanning::Baseline::Map]
  # @param data [Hash]
  # @return [TeamPlanning::Baseline::Map] the person marked; {TeamPlanning::Baseline::Map#settled}
  #   takes them off when the departure was set in an earlier step
  def self.apply_to(map, data)
    unless map.people.any? { it.id == data[:subject_id] }
      return map.with(unresolved: map.unresolved + [ TeamPlanning::Baseline::Unresolved.new(person_id: data[:subject_id], why: nil) ])
    end

    departure = data.slice(:leaves_in_id, :position_id)
    map.with(people: map.people.map { it.id == data[:subject_id] ? it.with(departure:) : it })
  end

  # @param map [TeamPlanning::Baseline::Map]
  # @param subject_id [String]
  # @param facet [String]
  # @return [Hash, nil] the departure, nil when the map has none for the person
  def self.read_from(map, subject_id:, facet: self.facet)
    map.people.find { it.id == subject_id }&.departure ||
      map.departed.find { it.person_id == subject_id }&.to_h&.slice(:leaves_in_id, :position_id)
  end

  # @param change [OrgGraph::ChangesBetween::Change]
  # @return [String, nil] the person, when the Org Graph has them leave
  def self.subject_moved_by(change) = (change.person_id if change.kind == :left)
end
