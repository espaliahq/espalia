# frozen_string_literal: true

# Where a unit stands in a scenario and what it is called: a unit the plan
# creates, or an Org Graph unit renamed or moved. It shares its facet with
# {UnitRetired}, so a later UnitSet brings a retired unit back.
#
# Only the Org Graph changes the type of a unit it holds, so the plan follows
# it: the `level_id` such a unit's UnitSet carries is not a planned value. A
# unit the plan created keeps its own.
#
# @!attribute [r] data
#   @return [Hash] the fields every {Change} holds, plus:
#   @option data [String] :name
#   @option data [String, nil] :parent_id nil for a unit at the top
#   @option data [String] :level_id an Org Graph taxonomy level
class TeamPlanning::Events::UnitSet < TeamPlanning::Events::Change
  FACET = "unit"
  ID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
  MOVED_BY = %i[unit_created unit_renamed unit_moved unit_retired].freeze

  def self.facet = FACET

  # @param data [Hash]
  # @return [Array<String>] the parent unit, if any
  def self.refers_to(data) = [ data[:parent_id] ].compact

  # @return [Boolean]
  def self.creates_subject? = true

  # @param end_state [Hash] `{ name:, parent_id:, level_id: }`
  # @return [Hash]
  # @raise [TeamPlanning::Error] for a blank or long name, or a level or parent that isn't an id
  def self.end_state(end_state)
    name = end_state[:name].to_s.squish
    raise TeamPlanning::Error, "A unit needs a name" if name.empty?

    limit = TeamPlanning::PlanAggregate::NAME_LIMIT
    raise TeamPlanning::Error, "A unit's name can be at most #{limit} characters" if name.length > limit

    { name:, parent_id: TeamPlanning::Events::UnitSet.id_or_nil(end_state[:parent_id], "parent"),
      level_id: TeamPlanning::Events::UnitSet.id_or_nil(end_state[:level_id], "level") ||
        raise(TeamPlanning::Error, "A unit needs a level") }
  end

  # @param map [TeamPlanning::Baseline::Map]
  # @param data [Hash]
  # @return [TeamPlanning::Baseline::Map] with the unit live, as this change left it
  def self.apply_to(map, data)
    id = data[:subject_id]
    known = (map.units + map.retired_units).find { it.id == id }
    level_id = map.org_unit_levels.fetch(id, data[:level_id])
    unit = TeamPlanning::Baseline::Unit.new(id:, name: data[:name], parent_id: data[:parent_id], level_id:,
                                            owner_ids: known&.owner_ids || [])
    map.with(units: (map.units.reject { it.id == id } + [ unit ]).sort_by { [ it.name, it.id ] },
             retired_units: map.retired_units.reject { it.id == id })
  end

  # @param map [TeamPlanning::Baseline::Map]
  # @param subject_id [String]
  # @return [Hash, nil] the unit as it stands, nil unless it is live
  def self.read_from(map, subject_id:, facet: self.facet)
    map.units.find { it.id == subject_id }&.to_h&.slice(:name, :parent_id, :level_id)
  end

  # A plan creates a unit only under an id the Org Graph never held, so a unit
  # the Org Graph reads is one whose type the plan doesn't set.
  #
  # @param read [Hash, nil]
  # @param planned [Hash, nil]
  # @param map [TeamPlanning::Baseline::Map]
  # @return [Boolean]
  def self.shows?(read, planned, map:)
    return same_end_state?(read, planned) unless read && planned

    same_end_state?(read.as_json.except("level_id"), planned.as_json.except("level_id"))
  end

  # @param change [OrgGraph::ChangesBetween::Change]
  # @return [String, nil] the unit an Org Graph change creates, renames, moves or retires
  def self.subject_moved_by(change) = (change.unit_id if MOVED_BY.include?(change.kind))

  # @param value [String, nil]
  # @param what [String] named in the refusal
  # @return [String, nil] the id, downcased
  # @raise [TeamPlanning::Error] unless blank or a UUID
  def self.id_or_nil(value, what)
    return nil if value.blank?
    return value.downcase if value.is_a?(String) && value.match?(ID)

    raise TeamPlanning::Error, "The #{what} must be an id"
  end
end
