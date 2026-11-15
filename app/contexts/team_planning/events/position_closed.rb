# frozen_string_literal: true

# A position a scenario closes. It shares {PositionSet}'s facet, so whichever
# came last wins: a later PositionSet reopens it.
#
# @!attribute [r] data
#   @return [Hash] {TeamPlanning::Events::Change::FIELDS} only
#   @option data [String] :subject_id the position id
#
class TeamPlanning::Events::PositionClosed < TeamPlanning::Events::Change
  # @return [String]
  def self.facet = TeamPlanning::Events::PositionSet.facet

  # @param end_state [Hash]
  # @return [Hash] always empty: a close says nothing but that it closed
  def self.end_state(_end_state) = {}

  # @param map [TeamPlanning::Baseline::Map]
  # @param data [Hash]
  # @return [TeamPlanning::Baseline::Map]
  def self.apply_to(map, data)
    map.with(positions: map.positions.reject { it.id == data[:subject_id] }, cut_positions: map.cut_positions.reject { it.id == data[:subject_id] })
  end
end
