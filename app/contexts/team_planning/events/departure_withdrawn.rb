# frozen_string_literal: true

# Someone a scenario has stay after all. It shares {DepartureSet}'s facet, so
# whichever came last wins, and the backfill link goes with the departure.
#
# @!attribute [r] data
#   @return [Hash] {TeamPlanning::Events::Change::FIELDS} only
#   @option data [String] :subject_id the person's id
#
class TeamPlanning::Events::DepartureWithdrawn < TeamPlanning::Events::Change
  # @return [String]
  def self.facet = TeamPlanning::Events::DepartureSet.facet

  # @param end_state [Hash]
  # @return [Hash] always empty
  def self.end_state(_end_state) = {}

  # @param map [TeamPlanning::Baseline::Map]
  # @param data [Hash]
  # @return [TeamPlanning::Baseline::Map]
  def self.apply_to(map, data) = map.with(people: map.people.map { it.id == data[:subject_id] ? it.with(departure: nil) : it })
end
