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
  # @!attribute change [TeamPlanning::Events::Change, nil] the later to land
  #   of the subject's own winning change and the change that broke it, so a
  #   child's placement under an ancestor's retirement names the placement,
  #   and a later retirement under an earlier placement names the retirement;
  #   nil only when no change explains it
  Item = Data.define(:subject_id, :facet, :reason, :change)

  CHECKS = %i[placements positions units unresolved successions capacity_overrides allocations leavers managers].freeze
  ASSIGNMENT = TeamPlanning::Events::AssignmentSet.facet
  POSITION = TeamPlanning::Events::PositionSet.facet
  UNIT = TeamPlanning::Events::UnitSet.facet
  SUCCESSION = TeamPlanning::Events::UnitSuccessionSet.facet
  LINE = TeamPlanning::Events::ReportingLineSet.facet
  CAPACITY = TeamPlanning::Events::CapacitySet.facet

  # @param map [TeamPlanning::Baseline::Map] settled, as {TeamPlanning::Resolution#structure} gives it
  # @param changes [Hash{Array(String, String) => TeamPlanning::Events::Change}] the winning changes, by key
  # @param left_ids [Array<String>] the people the Org Graph has had leave by today
  def initialize(map, changes, left_ids: [])
    @map = map
    @changes = changes
    @left = left_ids.to_set
    @order = changes.keys.each_with_index.to_h
    @live = map.units.to_set(&:id)
    @retired = map.retired_units.to_set(&:id)
  end

  # @return [Array<Item>] in {CHECKS} order, then by subject id and reason
  def call = CHECKS.flat_map { |check| send(check).sort_by { [ it.subject_id, it.reason ] } }

  private

  # A position's own unit is the position's item, not each occupant's.
  def placements
    open = @map.positions.to_set(&:id)
    @map.people.flat_map do |person|
      breaks = person.memberships.filter_map do |place|
        if place.position_id
          [ "Placed in a closed position", [ place.position_id, POSITION ] ] unless open.include?(place.position_id)
        elsif !@live.include?(place.unit_id)
          [ "Placed in #{gone(place.unit_id)}", [ place.unit_id, UNIT ] ]
        end
      end
      breaks.group_by(&:first).map { |reason, pairs| item(person.id, ASSIGNMENT, reason, broken_by: pairs.map(&:last)) }
    end
  end

  def positions
    by_position = @map.occupants
    @map.positions.flat_map do |position|
      held = by_position.fetch(position.id, [])
      open_fte = @map.open_fte(position, held)
      [ (item(position.id, POSITION, "In #{gone(position.unit_id)}", broken_by: [ [ position.unit_id, UNIT ] ]) unless @live.include?(position.unit_id)),
        (item(position.id, POSITION, "Overfilled by #{fte(-open_fte)} FTE", broken_by: held.map { [ it.first.id, ASSIGNMENT ] }) if open_fte.negative?) ].compact
    end
  end

  def units
    @map.units.filter_map do |unit|
      next if unit.parent_id.nil? || @live.include?(unit.parent_id)

      item(unit.id, UNIT, "Its parent is #{gone(unit.parent_id)}", broken_by: [ [ unit.parent_id, UNIT ] ])
    end
  end

  def unresolved
    @map.unresolved.map { item(it.person_id, ASSIGNMENT, "Placed, but #{it.why}") }
  end

  def successions
    @map.successions.flat_map do |succession|
      gone_before = succession.predecessor_ids.reject { @live.include?(it) || @retired.include?(it) }
      still_live = succession.predecessor_ids.select { @live.include?(it) }
      gone_after = succession.successor_ids.reject { @live.include?(it) }
      [ (item(succession.id, SUCCESSION, "It carries on from a unit no longer in this scenario", broken_by: gone_before.map { [ it, UNIT ] }) if gone_before.any?),
        (item(succession.id, SUCCESSION, "It carries on from a unit that is still live", broken_by: still_live.map { [ it, UNIT ] }) if still_live.any?),
        (item(succession.id, SUCCESSION, "It is carried on by #{gone(gone_after.first)}", broken_by: gone_after.map { [ it, UNIT ] }) if gone_after.any?) ].compact
    end
  end

  # Capacity prices a place in a position by the position, so an override on
  # the unit around it is one no place reads.
  def capacity_overrides
    @map.people.flat_map do |person|
      held = person.memberships.to_set { it.position_id || it.unit_id }
      person.capacity_overrides.keys.reject { held.include?(it) }.sort.map do |place_id|
        item(person.id, "#{CAPACITY}:#{place_id}", "Overrides capacity in a place they don't hold", broken_by: [ [ person.id, ASSIGNMENT ] ])
      end
    end
  end

  # Someone placed only in a gone unit or a closed position has that item
  # already, so placed nowhere is someone with no place at all. An unknown
  # total is never under-allocated.
  def allocations
    totals = @map.allocation_totals
    @map.people.filter_map do |person|
      total = totals[person.id]
      reason = if person.memberships.empty? then "Placed nowhere"
      elsif total.nil? || total.zero? then nil
      elsif total > 1 then "Over-allocated, at #{percent(total)}"
      elsif total < 1 then "Under-allocated, at #{percent(total)}"
      end
      item(person.id, ASSIGNMENT, reason) if reason
    end
  end

  def leavers
    @map.people.filter_map do |person|
      next unless @left.include?(person.id) && person.memberships.any? && !person.leaving?

      item(person.id, ASSIGNMENT, "Placed, but has since left")
    end
  end

  # The head of the tree owns a unit with no parent, so has no manager by
  # right. A manager shares a unit when they are in or own one of the
  # person's units, or the unit above it, so a lead reporting to the owner
  # of the group around their team is not marked.
  def managers
    by_id = @map.people.index_by(&:id)
    positions = @map.positions.index_by(&:id)
    heads = @map.units.select { it.parent_id.nil? }.flat_map(&:owner_ids).to_set
    @map.people.filter_map do |person|
      reason = manager_reason(person, by_id, positions, heads)
      item(person.id, LINE, reason, broken_by: [ [ person.id, ASSIGNMENT ] ]) if reason
    end
  end

  def manager_reason(person, by_id, positions, heads)
    return (heads.include?(person.id) ? nil : "Has no manager") unless (line = person.line)

    nearby = near_units(person)
    if line.person_id
      manager = by_id[line.person_id]
      return "Their manager is no longer in this scenario" unless manager
      return if nearby.empty?

      "Their manager shares no unit with them" unless nearby.intersect?(units_of(manager))
    else
      position = positions[line.position_id]
      return "Their manager's position is no longer in this scenario" unless position
      return if nearby.empty?

      "Their manager's position shares no unit with them" unless nearby.include?(position.unit_id)
    end
  end

  def near_units(person)
    parent = @map.units.to_h { [ it.id, it.parent_id ] }
    own = person.memberships.map(&:unit_id).select { @live.include?(it) }
    (own + own.filter_map { parent[it] }).to_set
  end

  def units_of(person) = person.memberships.map(&:unit_id).compact.to_set | @map.units.select { it.owner_ids.include?(person.id) }.to_set(&:id)

  def percent(total) = "#{fte(total * 100)}%"

  def item(subject_id, facet, reason, broken_by: [])
    keys = [ [ subject_id, facet ], *broken_by ].select { @order.key?(it) }
    Item.new(subject_id:, facet:, reason:, change: keys.max_by { @order[it] }&.then { @changes[it] })
  end

  def gone(unit_id) = @retired.include?(unit_id) ? "a retired unit" : "a unit no longer in this scenario"

  def fte(value) = value.round(4).to_s.delete_suffix(".0")
end
