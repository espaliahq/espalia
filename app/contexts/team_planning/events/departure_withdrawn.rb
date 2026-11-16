# frozen_string_literal: true

# Someone a scenario has stay after all. It shares {DepartureSet}'s facet, so
# whichever came last wins, and the backfill link goes with the departure.
#
# @!attribute [r] data
#   @return [Hash] {TeamPlanning::Events::Change::FIELDS} only
#   @option data [String] :subject_id the person's id
#
class TeamPlanning::Events::DepartureWithdrawn < TeamPlanning::Events::Change
  about_a_person

  # @return [String]
  def self.facet = TeamPlanning::Events::DepartureSet.facet

  # @param end_state [Hash]
  # @return [Hash] always empty
  def self.end_state(_end_state) = {}

  # @param map [TeamPlanning::Baseline::Map]
  # @param data [Hash]
  # @return [TeamPlanning::Baseline::Map]
  def self.apply_to(map, data) = map.holds?(data[:subject_id]) ? map.updating(data[:subject_id]) { it.with(departure: nil) } : map

  # A person on the map who isn't leaving, so a scenario can pin that they
  # stay when nothing it follows has them leave.
  #
  # @param map [TeamPlanning::Baseline::Map]
  # @param subject_id [String]
  # @param facet [String]
  # @return [Hash, nil] empty when they stay, nil when they leave or aren't on the map
  def self.read_from(map, subject_id:, facet: self.facet) = (map.people.any? { it.id == subject_id && !it.leaving? } ? {} : nil)

  # The Org Graph knows only who has left, so the person stays until it has them
  # leave. A leaver reads as neither staying nor a planned departure, which reads
  # nil here, so a withdrawal the person has since broken never reads pending.
  #
  # @param map [TeamPlanning::Baseline::Map] read off the Org Graph
  # @param change [TeamPlanning::Events::DepartureWithdrawn]
  # @return [Hash] empty while they stay, `{ left: true }` once they have left
  def self.read_org_graph(map, change) = (map.left_ids.include?(change.data[:subject_id]) ? { left: true } : {})
end
