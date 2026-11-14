# frozen_string_literal: true

# A unit wound down in a scenario. It shares its facet with {UnitSet}, so the
# last of the two wins. Its people keep their place: moving them is an
# assignment's job, and a place in a retired unit is a misfit.
class TeamPlanning::Events::UnitRetired < TeamPlanning::Events::Change
  def self.facet = TeamPlanning::Events::UnitSet::FACET

  # @param end_state [Hash] nothing; a retirement has no fields of its own
  # @return [Hash]
  def self.end_state(_end_state) = {}

  # @param map [TeamPlanning::Baseline::Map]
  # @param data [Hash]
  # @return [TeamPlanning::Baseline::Map] with the unit among the retired, if the map knew it
  def self.apply_to(map, data)
    unit = map.units.find { it.id == data[:subject_id] }
    return map unless unit

    map.with(units: map.units - [ unit ], retired_units: map.retired_units + [ unit ])
  end
end
