# frozen_string_literal: true

# What no longer fits in a resolved scenario. A write refuses only a
# malformed change, so an ancestor's later edit can leave a descendant's
# change standing on something gone: a placement in a unit the parent
# retired, a position someone closed. Those changes still resolve; this
# read marks them, each with a reason and the change it belongs to.
#
# It also checks each person: allocation, someone still placed after the
# Org Graph has them leave, and their manager (4.6).
#
# Derived from the map and the changes that won, never stored. The changes
# tab (4.4) and the checks tab (4.7) both read it.
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
  # @!attribute unit_ids [Array<String>] the units it touches, whose providers are its source of truth
  # @!attribute fact [String, nil] the person fact it rests on instead, for someone the plan can't place
  Item = Data.define(:subject_id, :facet, :reason, :change, :unit_ids, :fact) do
    def initialize(unit_ids: [], fact: nil, **) = super
  end

  CHECKS = %i[placements positions units unresolved successions capacity_overrides allocations leavers managers unclassified
              budget_lines].freeze
  ASSIGNMENT = TeamPlanning::Events::AssignmentSet.facet
  POSITION = TeamPlanning::Events::PositionSet.facet
  UNIT = TeamPlanning::Events::UnitSet.facet
  SUCCESSION = TeamPlanning::Events::UnitSuccessionSet.facet
  LINE = TeamPlanning::Events::ReportingLineSet.facet
  CAPACITY = TeamPlanning::Events::CapacitySet.facet
  LEVEL = TeamPlanning::Events::LevelSet.facet
  BUDGET_LINE = TeamPlanning::Events::BudgetLineSet.facet
  DEPARTURE = TeamPlanning::Events::DepartureSet.facet
  UNSHARED = [ "Their manager shares no unit with them", "Their manager's position shares no unit with them" ].freeze
  # A place in no unit has no id an override could name, as the map's own drop target hasn't.
  UNASSIGNED = "unassigned"

  # @param map [TeamPlanning::Baseline::Map] settled, as {TeamPlanning::Resolution#structure} gives it
  # @param changes [Hash{Array(String, String) => TeamPlanning::Events::Change}] the winning changes, by key
  # @param left_ids [Array<String>] the people the Org Graph has had leave by today
  # @param closed_units [Hash{String => String}] the unit of each position the scenario closed
  # @param unclassified [Array<Array(TeamPlanning::Capacity::Seat, TeamPlanning::Capacity::Place)>] from {TeamPlanning::Capacity::Report#unclassified}
  def initialize(map, changes, left_ids: [], closed_units: {}, unclassified: [])
    @map = map
    @position_units = closed_units.merge(map.positions.to_h { [ it.id, it.unit_id ] })
    @unclassified = unclassified
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
      away = @map.outside_places(person)
      breaks = (person.memberships - away).filter_map do |place|
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

  # A unit the plan covers sits under one it doesn't, so its parent is never gone.
  def units
    roots = @map.scope_ids.to_a.to_set
    parted = @map.units.filter_map do |unit|
      next if unit.parent_id.nil? || @live.include?(unit.parent_id) || roots.include?(unit.id)

      item(unit.id, UNIT, "Its parent is #{gone(unit.parent_id)}", broken_by: [ [ unit.parent_id, UNIT ] ])
    end
    parted + (roots - @live - @retired).map { item(it, UNIT, "The plan covers it, but the organisation no longer has it") }
  end

  def unresolved
    @map.unresolved.map { item(it.person_id, ASSIGNMENT, "Placed, but #{it.why}", fact: "employment_status") }
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
  # total is never under-allocated, and someone who has left is the
  # leavers' item. A place that drops out of the total can leave the rest
  # short, so the change that dropped it can explain an under-allocation.
  def allocations
    totals = @map.allocation_totals
    @map.people.filter_map do |person|
      total = totals[person.id]
      if gone?(person) then nil
      elsif person.memberships.empty? then item(person.id, ASSIGNMENT, "Placed nowhere")
      elsif total.nil? || total.zero? then nil
      elsif total > 1 then item(person.id, ASSIGNMENT, "Over-allocated, at #{percent(total)}", units: places_of(person))
      elsif total < 1 then item(person.id, ASSIGNMENT, "Under-allocated, at #{percent(total)}", broken_by: dropped_keys(person), units: places_of(person))
      end
    end
  end

  def places_of(person) = person.memberships.map { it.position_id ? @position_units[it.position_id] : it.unit_id }

  def dropped_keys(person)
    (person.memberships - @map.outside_places(person)).reject { @live.include?(it.unit_id) }.flat_map do |place|
      [ ([ place.position_id, POSITION ] if place.position_id), ([ place.unit_id, UNIT ] if place.unit_id) ].compact
    end
  end

  def leavers
    @map.people.filter_map do |person|
      next unless gone?(person)

      item(person.id, ASSIGNMENT, person.memberships.any? ? "Placed, but has since left" : "Has since left", fact: "employment_status")
    end
  end

  # The head of the tree owns a unit with no parent, so has no manager by
  # right. A manager shares a unit when they are in or own one of the
  # person's units, or the unit above it, so a lead reporting to the owner
  # of the group around their team is not marked. A position in a gone unit
  # is that position's item, not each report's.
  def managers
    by_id = @map.people.index_by(&:id)
    positions = @map.positions.index_by(&:id)
    heads = @map.units.select { it.parent_id.nil? }.flat_map(&:owner_ids).to_set
    @parents = @map.units.to_h { [ it.id, it.parent_id ] }
    @owned = @map.units.each_with_object(Hash.new { |hash, id| hash[id] = Set.new }) { |unit, owned| unit.owner_ids.each { owned[it] << unit.id } }
    @map.people.filter_map do |person|
      next unless (reason = manager_reason(person, by_id, positions, heads))

      placing = UNSHARED.include?(reason) ? placing_keys(person, by_id[person.line.person_id]) : []
      item(person.id, LINE, reason, broken_by: [ [ person.id, ASSIGNMENT ], *placing, *manager_keys(person.line), *owned_keys(person) ],
                                    fact: "manager")
    end
  end

  # A seat in a position sits in the position's unit, so moving the position
  # can part a report from their manager as surely as moving either of them.
  def placing_keys(person, manager)
    seats = [ person, manager ].compact.flat_map(&:memberships).filter_map { [ it.position_id, POSITION ] if it.position_id }
    [ *near_units(person).map { [ it, UNIT ] }, *seats ]
  end

  # Giving a unit someone owns a parent takes them off the head of the tree.
  def owned_keys(person) = person.line ? [] : @owned[person.id].map { [ it, UNIT ] }

  def manager_keys(line)
    return [] unless line

    line.person_id ? [ [ line.person_id, ASSIGNMENT ], [ line.person_id, DEPARTURE ] ] : [ [ line.position_id, POSITION ] ]
  end

  def manager_reason(person, by_id, positions, heads)
    return (heads.include?(person.id) ? nil : "Has no manager") unless (line = person.line)

    nearby = near_units(person)
    if line.person_id
      return if @map.outside?(line.person_id)

      manager = by_id[line.person_id]
      return "Their manager is no longer in this scenario" unless manager
      return "Their manager has since left" if @left.include?(manager.id)
      return if nearby.empty?

      UNSHARED.first unless nearby.intersect?(units_of(manager))
    else
      position = positions[line.position_id]
      return "Their manager's position is no longer in this scenario" unless position
      return if nearby.empty? || !@live.include?(position.unit_id)

      UNSHARED.last unless nearby.include?(position.unit_id)
    end
  end

  def near_units(person)
    own = person.memberships.map(&:unit_id).select { @live.include?(it) }
    (own + own.filter_map { @parents[it] }).to_set
  end

  def units_of(person) = person.memberships.map(&:unit_id).compact.to_set | @owned[person.id]

  def gone?(person) = @left.include?(person.id) && !person.leaving?

  def percent(total) = "#{fte(total * 100)}%"

  # A leaver's backfill carries their seat, a forgotten person's override is
  # gone with them, and a closed position is the placements check's item.
  UNCLASSIFIED_ELSEWHERE = %w[leaving override_unknown closed_position].freeze

  def unclassified
    @unclassified.reject { |_, place| UNCLASSIFIED_ELSEWHERE.include?(place.reason) }.map do |priced, place|
      seat = priced.seat
      facet = "#{CAPACITY}:#{place.place.position_id || place.unit_id || UNASSIGNED}"
      item(seat.id, facet, "Counts for no capacity: #{TeamPlanning::Capacity::REASONS.fetch(place.reason).downcase_first}",
           broken_by: unclassified_causes(seat, place))
    end
  end

  # A place in a position takes the position's role and level, so a later
  # edit to the position can be what left its occupant uncovered. A missing
  # model or level can also be a capacity rule's doing, set at the place's
  # unit, above it or plan-wide, or the unit's retirement, which drops the
  # rule set there.
  def unclassified_causes(seat, place)
    rules = RULE_REASONS.include?(place.reason) ? rule_keys(place.unit_id) : []
    return [ [ seat.id, POSITION ], *rules ] unless seat.kind == "person"

    position_id = place.place.position_id
    level = [ seat.id, LEVEL ] if place.reason == "no_level" && !position_id
    [ [ seat.id, ASSIGNMENT ], level, ([ position_id, POSITION ] if position_id), *rules ].compact
  end

  RULE_REASONS = %w[no_model unknown_model no_level].freeze
  CAPACITY_RULE = "#{TeamPlanning::Events::RuleSet.facet}:#{TeamPlanning::RuleKinds::Capacity.rule_name}".freeze

  def rule_keys(unit_id)
    parent_of = @map.units.to_h { [ it.id, it.parent_id ] }
    along = []
    while parent_of.key?(unit_id) && along.exclude?(unit_id)
      along << unit_id
      unit_id = parent_of[unit_id]
    end
    retired = [ [ unit_id, UNIT ] ] if unit_id && along.empty?
    [ *(along + [ @map.rules.plan_id ]).map { [ it, CAPACITY_RULE ] }, *retired ]
  end

  # The tenant removed a line the plan changed or cut, so the change stands on nothing.
  def budget_lines
    @map.orphaned_lines.map do |line_id, kind|
      item(line_id, BUDGET_LINE, "#{kind == 'cut' ? 'Cuts' : 'Changes'} a budget line the organisation has since removed")
    end
  end

  # @param units [Array<String>] units the item touches beyond its subject's and broken_by's
  def item(subject_id, facet, reason, broken_by: [], fact: nil, units: [])
    keys = [ [ subject_id, facet ], *broken_by ].select { @order.key?(it) }
    Item.new(subject_id:, facet:, reason:, change: keys.max_by { @order[it] }&.then { @changes[it] },
             unit_ids: (units + units_touched(subject_id, facet, broken_by)).compact.uniq, fact:)
  end

  def units_touched(subject_id, facet, broken_by)
    own = case facet
    when UNIT then [ subject_id ]
    when POSITION then [ @position_units[subject_id] ]
    when SUCCESSION then @map.successions.find { it.id == subject_id }&.then { it.predecessor_ids + it.successor_ids }
    when /\A#{CAPACITY}:/ then [ place_unit(facet.delete_prefix("#{CAPACITY}:")) ]
    else []
    end
    broken = broken_by.filter_map { |id, kind| { UNIT => id, POSITION => @position_units[id] }[kind] }
    (own.to_a + broken).compact.uniq
  end

  # A capacity facet names a unit, a position, or no unit at all.
  def place_unit(place_id) = place_id == UNASSIGNED ? nil : @position_units.fetch(place_id, place_id)

  def gone(unit_id) = @retired.include?(unit_id) ? "a retired unit" : "a unit no longer in this scenario"

  def fte(value) = value.round(4).to_s.delete_suffix(".0")
end
