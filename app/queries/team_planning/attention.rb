# frozen_string_literal: true

# What no longer fits in a resolved scenario. A write refuses only a
# malformed change, so an ancestor's later edit can leave a descendant's
# change standing on something gone: a placement in a unit the parent
# retired, a position someone closed. Those changes still resolve; this
# read marks them, each with a reason and the change it belongs to.
#
# Derived from the map and the changes that won, never stored. The checks
# projection (4.6) and the changes tab (4.4) both read it.
#
# @example
#   TeamPlanning::Resolution.new(context:, plan:, scenario_id:).attention
class TeamPlanning::Attention
  # One thing that no longer fits.
  #
  # @!attribute subject_id [String] the person, unit, position or succession
  # @!attribute facet [String] the facet of the subject that no longer fits
  # @!attribute reason [String] a sentence a planner can read
  # @!attribute change [TeamPlanning::Events::Change, nil] the subject's own
  #   winning change, or else the change that broke it; nil only when the
  #   baseline itself doesn't fit
  Item = Data.define(:subject_id, :facet, :reason, :change)

  CHECKS = %i[placements positions units unresolved successions].freeze
  ASSIGNMENT = TeamPlanning::Events::AssignmentSet.facet
  POSITION = TeamPlanning::Events::PositionSet.facet
  UNIT = TeamPlanning::Events::UnitSet.facet
  SUCCESSION = TeamPlanning::Events::UnitSuccessionSet.facet

  # @param map [TeamPlanning::Baseline::Map] settled, as {TeamPlanning::Resolution#structure} gives it
  # @param changes [Hash{Array(String, String) => TeamPlanning::Events::Change}] the winning changes, by key
  def initialize(map, changes)
    @map = map
    @changes = changes
    @live = map.units.to_set(&:id)
    @retired = map.retired_units.to_set(&:id)
  end

  # @return [Array<Item>] in check order, then map order
  def call = CHECKS.flat_map { send(it) }

  private

  # A position's own unit is the position's item, not each occupant's.
  def placements
    open = @map.positions.to_set(&:id)
    @map.people.flat_map do |person|
      person.memberships.filter_map do |place|
        if place.position_id
          next if open.include?(place.position_id)

          item(person.id, ASSIGNMENT, "Placed in a closed position", broken_by: [ place.position_id, POSITION ])
        elsif !@live.include?(place.unit_id)
          item(person.id, ASSIGNMENT, "Placed in #{gone(place.unit_id)}", broken_by: [ place.unit_id, UNIT ])
        end
      end.uniq
    end
  end

  def positions
    by_position = @map.occupants
    @map.positions.flat_map do |position|
      held = by_position.fetch(position.id, [])
      open_fte = @map.open_fte(position, held)
      [ (item(position.id, POSITION, "In #{gone(position.unit_id)}", broken_by: [ position.unit_id, UNIT ]) unless @live.include?(position.unit_id)),
        (item(position.id, POSITION, "Overfilled by #{fte(-open_fte)} FTE") if open_fte.negative?) ].compact
    end
  end

  def units
    @map.units.filter_map do |unit|
      next if unit.parent_id.nil? || @live.include?(unit.parent_id)

      item(unit.id, UNIT, "Its parent is #{gone(unit.parent_id)}", broken_by: [ unit.parent_id, UNIT ])
    end
  end

  def unresolved
    @map.unresolved.map { item(it.person_id, ASSIGNMENT, "Placed, but #{it.why}") }
  end

  def successions
    @map.successions.flat_map do |succession|
      gone_before = succession.predecessor_ids.reject { @live.include?(it) || @retired.include?(it) }
      gone_after = succession.successor_ids.reject { @live.include?(it) }
      [ ("It carries on from a unit no longer in this scenario" if gone_before.any?),
        ("It is carried on by #{gone(gone_after.first)}" if gone_after.any?) ].compact
        .map { item(succession.id, SUCCESSION, it, broken_by: [ (gone_before + gone_after).first, UNIT ]) }
    end
  end

  def item(subject_id, facet, reason, broken_by: nil)
    Item.new(subject_id:, facet:, reason:, change: @changes[[ subject_id, facet ]] || @changes[broken_by])
  end

  def gone(unit_id) = @retired.include?(unit_id) ? "a retired unit" : "a unit no longer in this scenario"

  def fte(value) = value.round(2).to_s.delete_suffix(".0")
end
