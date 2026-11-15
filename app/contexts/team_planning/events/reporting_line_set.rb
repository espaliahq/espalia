# frozen_string_literal: true

# Who a person reports to in a scenario: a person, a position (a vacant
# manager seat, so a team whose manager is being hired isn't credited to
# whoever the HRIS still lists), or nobody. Reporting lines are a graph over
# people and seats, never read from the unit tree. The baseline line is the
# Org Graph's manager fact.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :subject_id the person's id
#   @option data [String, nil] :manager_id the person they report to
#   @option data [String, nil] :manager_position_id the position they report to; nil when manager_id is set
#   Plus {TeamPlanning::Events::Change::FIELDS}.
#
class TeamPlanning::Events::ReportingLineSet < TeamPlanning::Events::Change
  about_a_person

  TARGETS = %i[manager_id manager_position_id].freeze

  # @return [String]
  def self.facet = "reporting_line"

  # @param data [Hash]
  # @return [Array<String>] the manager or the position they report to
  def self.refers_to(data) = data.values_at(:manager_id, :manager_position_id).compact

  # @param end_state [Hash] `{ manager_id: }`, `{ manager_position_id: }`, or neither for no manager
  # @return [Hash] both keys, the ids downcased, one or both nil
  # @raise [TeamPlanning::Error] when both are given
  def self.end_state(end_state)
    targets = TARGETS.to_h { [ it, end_state[it].to_s.strip.downcase.presence ] }
    raise TeamPlanning::Error, "A person reports to a person or a position, not both" if targets.values.all?

    targets
  end

  # @param map [TeamPlanning::Baseline::Map]
  # @param data [Hash]
  # @return [TeamPlanning::Baseline::Map] for a person the map doesn't have, the line waits in `unresolved`
  def self.apply_to(map, data)
    unless map.people.any? { it.id == data[:subject_id] }
      return map.with(unresolved: map.unresolved + [ TeamPlanning::Baseline::Unresolved.new(person_id: data[:subject_id], why: nil) ])
    end

    map.with(people: map.people.map { it.id == data[:subject_id] ? it.with(**data.slice(*TARGETS)) : it })
  end

  # @param map [TeamPlanning::Baseline::Map]
  # @param subject_id [String]
  # @param facet [String]
  # @return [Hash, nil] the person's line, nil for a person not on the map
  def self.read_from(map, subject_id:, facet: self.facet)
    map.people.find { it.id == subject_id }&.then { it.to_h.slice(*TARGETS) }
  end

  # The Org Graph names a manager, never a seat, so a line to a position
  # shows as a line to someone who holds it on the plan's map.
  #
  # @param read [Hash, nil] the line read off the Org Graph
  # @param planned [Hash, nil]
  # @param map [TeamPlanning::Baseline::Map] settled, so each seat has its holders
  # @return [Boolean]
  def self.shows?(read, planned, map:)
    seat = planned&.as_json&.dig("manager_position_id")
    return same_end_state?(read, planned) unless read && seat

    manager_id = read.as_json["manager_id"]
    map.occupants.fetch(seat, []).any? { |holder, _| holder.id == manager_id }
  end

  # @param change [OrgGraph::ChangesBetween::Change]
  # @return [String, nil] the person, when their manager fact changed
  def self.subject_moved_by(change) = (change.person_id if change.kind == :fact_changed && change.fact == "manager")
end
