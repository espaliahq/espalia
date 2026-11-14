# frozen_string_literal: true

# A unit wound down in a scenario. It shares its facet with {UnitSet}, so the
# last of the two wins, and it carries the unit as it stood, since winning
# drops any UnitSet before it: the one that created the unit, or renamed it.
# Its people keep their place: moving them is an assignment's job, and a
# place in a retired unit is a misfit.
#
# @!attribute [r] data
#   @return [Hash] the fields every {Change} holds, plus the unit's `name`,
#     `parent_id` and `level_id` as {UnitSet} holds them
class TeamPlanning::Events::UnitRetired < TeamPlanning::Events::Change
  def self.facet = TeamPlanning::Events::UnitSet::FACET

  # @param end_state [Hash] `{ name:, parent_id:, level_id: }`, the unit as it stood
  # @return [Hash]
  # @raise [TeamPlanning::Error] as {UnitSet.end_state} does
  def self.end_state(end_state) = TeamPlanning::Events::UnitSet.end_state(end_state)

  # @param map [TeamPlanning::Baseline::Map]
  # @param subject_id [String]
  # @return [Hash, nil] the unit as it stood when retired, nil unless it is retired
  def self.read_from(map, subject_id:, facet: self.facet)
    map.retired_units.find { it.id == subject_id }&.to_h&.slice(:name, :parent_id, :level_id)
  end

  # A unit the Org Graph has retired shows a planned retirement, whatever name it last held.
  #
  # @param read [Hash, nil]
  # @param planned [Hash, nil]
  # @param map [TeamPlanning::Baseline::Map]
  # @return [Boolean]
  def self.shows?(read, planned, map:) = read.nil? == planned.nil?

  # @param change [OrgGraph::ChangesBetween::Change]
  # @return [String, nil] the unit an Org Graph change creates, renames, moves or retires
  def self.subject_moved_by(change) = TeamPlanning::Events::UnitSet.subject_moved_by(change)

  # @param map [TeamPlanning::Baseline::Map]
  # @param data [Hash]
  # @return [TeamPlanning::Baseline::Map] with the unit among the retired, as it stood
  def self.apply_to(map, data)
    live = TeamPlanning::Events::UnitSet.apply_to(map, data)
    unit = live.units.find { it.id == data[:subject_id] }
    live.with(units: live.units - [ unit ], retired_units: live.retired_units + [ unit ])
  end
end
