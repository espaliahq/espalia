# frozen_string_literal: true

# What no longer fits in a resolved scenario. A write refuses only a
# malformed change, so an ancestor's later edit can leave a descendant's
# change standing on something gone: a placement in a unit the parent
# retired, a position someone closed. Those changes still resolve; this
# read marks them, each with a reason and the change it belongs to.
#
# It marks a unit whose type can no longer sit under its parent's, or at the
# top, once the Org Graph narrows where a type may sit: "Doesn't fit this
# structure" ([#390](https://github.com/espaliahq/espalia/issues/390)). Each
# unit is judged against the structure in force at it through the plan's
# tree, so a unit whose type belongs to another structure misfits too
# ([#494](https://github.com/espaliahq/espalia/issues/494)).
#
# It also checks each person: allocation, someone still placed after the
# Org Graph has them leave, and their manager (4.6), and each seat whose
# reports cost more to manage than it delivers (7.5), each open seat whose
# target start has passed (10.3), and a scenario's budget
# (6.6, [#421](https://github.com/espaliahq/espalia/issues/421)) as the
# budget read gives it to the viewer: positions unfunded or tied, seats with
# no cost centre, figures over budget and lines nothing draws on. Those read
# no figure of their own and name no money.
#
# Derived from the map and the changes that won, never stored. The changes
# tab (4.4) and the checks tab (4.7) both read it.
#
# @example
#   TeamPlanning::Attention.for(context:, plan:, scenario_id:)
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
  # @!attribute check [Symbol, nil] the entry in {CHECKS} that found it
  Item = Data.define(:subject_id, :facet, :reason, :change, :unit_ids, :fact, :check) do
    def initialize(unit_ids: [], fact: nil, check: nil, **) = super
  end

  # What a scenario's checks found, with a name for each subject the map can
  # name, read the way the map reads it.
  #
  # @!attribute items [Array<Item>] in {CHECKS} order
  # @!attribute names [Hash{String => String}] subject id => name
  Report = Data.define(:items, :names)

  CHECKS = %i[placements positions late_hires units misfits unresolved uncovered successions capacity_overrides allocations leavers managers overloaded
              unclassified budget_lines fundings unfunded ambiguous_funding unplaced cost_centre_mismatches budget_variance unused_budget_lines].freeze
  ASSIGNMENT = TeamPlanning::Events::AssignmentSet.facet
  POSITION = TeamPlanning::Events::PositionSet.facet
  UNIT = TeamPlanning::Events::UnitSet.facet
  SUCCESSION = TeamPlanning::Events::UnitSuccessionSet.facet
  LINE = TeamPlanning::Events::ReportingLineSet.facet
  CAPACITY = TeamPlanning::Events::CapacitySet.facet
  LEVEL = TeamPlanning::Events::LevelSet.facet
  BUDGET_LINE = TeamPlanning::Events::BudgetLineSet.facet
  DEPARTURE = TeamPlanning::Events::DepartureSet.facet
  FUNDING = TeamPlanning::Events::PositionFundingSet.facet
  COST_CENTRE = "cost_centre"
  BUDGET = "budget"
  UNSHARED = [ "Their manager shares no unit with them", "Their manager's position shares no unit with them" ].freeze
  # A place in no unit has no id an override could name, as the map's own drop target hasn't.
  UNASSIGNED = "unassigned"
  NO_COST_CENTRE = "no_cost_centre"
  UNCOVERED = "A change about someone this plan no longer covers"

  # Resolves the scenario, then prices it, so the unclassified check reads
  # the same map as every other.
  #
  # @param context [AuthorizationContext]
  # @param plan [TeamPlanningPlan]
  # @param scenario_id [String] the plan's id for the root
  # @param repository [TeamPlanning::Repository]
  # @return [Report]
  # @raise [Pundit::NotAuthorizedError] when the caller can't open the plan or see the Org Graph
  # @raise [TeamPlanning::Error] for a scenario the plan doesn't have
  def self.for(context:, plan:, scenario_id:, repository: TeamPlanning::Repository.new)
    resolution = TeamPlanning::Resolution.new(context:, plan:, scenario_id:, repository:)
    aggregate = repository.load_plan(plan.id)
    shared, changes = resolution.shared(aggregate)
    map = shared.map
    capacity = TeamPlanning::Capacity.new(resolution:, plan:).report_for(map)
    budget = TeamPlanning::Budget.new(context:, plan:, scenario_id:, repository:, aggregate:, shared:).call if scenario_id != plan.id && map.budget_lines.any?
    items = new(map, changes, left_ids: resolution.left_since(map), closed_units: resolution.closed_position_units(aggregate, changes),
                              unclassified: capacity.configured? ? capacity.unclassified : [], priced: capacity.seats, budget:,
                              structures: TeamPlanning::PlannedStructures.load(map)).call
    Report.new(items:, names: items.empty? ? {} : names_of(resolution.named(map), items))
  end

  PERSON_FACETS = [ ASSIGNMENT, LINE, LEVEL, DEPARTURE ].freeze
  REMOVED_UNIT = "A removed unit"

  # A person the map no longer names was forgotten. A unit, position or
  # succession it no longer holds has no name, as the map shows none.
  # Someone a scoped plan no longer covers stays unnamed.
  #
  # @param map [TeamPlanning::Baseline::Map] with names joined
  # @param items [Array<Item>]
  # @return [Hash{String => String}]
  def self.names_of(map, items)
    units = (map.units + map.retired_units).to_h { [ it.id, it.name ] }
    positions = map.positions.group_by(&:unit_id).each_value.reduce({}) do |names, group|
      names.merge(TeamPlanning::Baseline::Position.names(group.map { [ it.id, it.label, it.level_id ] }))
    end
    successions = map.successions.to_h { [ it.id, it ] }
    lines = map.budget_lines.to_h { [ it.id, line_name(it) ] }
    items.filter_map do |item|
      next if item.reason == UNCOVERED

      id = item.subject_id
      name = case item.facet.split(":").first
      when *PERSON_FACETS then map.name_of(id)
      when UNIT then units[id]
      when POSITION, FUNDING then positions[id]
      when BUDGET_LINE then lines[id]
      when COST_CENTRE then id == NO_COST_CENTRE ? "No cost centre" : id
      when SUCCESSION then successions[id]&.then { succession_name(it, units) }
      when CAPACITY then positions[id] || map.name_of(id)
      end
      [ id, name ] if name
    end.to_h
  end

  # As the budget tab names a line: its role and level, else any role, and its cost centre.
  def self.line_name(line) = [ [ line.role_name, line.level_name ].compact.join(", ").presence || "Any role", line.cost_centre.presence ].compact.join(" · ")
  private_class_method :line_name

  def self.succession_name(succession, units)
    sides = [ succession.predecessor_ids, succession.successor_ids ].map { |ids| ids.map { units.fetch(it, REMOVED_UNIT) }.join(", ") }
    sides.join(" → ")
  end
  private_class_method :succession_name

  # @param map [TeamPlanning::Baseline::Map] settled, as {TeamPlanning::Resolution#structure} gives it
  # @param changes [Hash{Array(String, String) => TeamPlanning::Events::Change}] the winning changes, by key
  # @param left_ids [Array<String>] the people the Org Graph has had leave by today
  # @param closed_units [Hash{String => String}] the unit of each position the scenario closed
  # @param unclassified [Array<Array(TeamPlanning::Capacity::Seat, TeamPlanning::Capacity::Place)>] from {TeamPlanning::Capacity::Report#unclassified}
  # @param priced [Array<TeamPlanning::Capacity::Seat>] from {TeamPlanning::Capacity::Report#seats}
  # @param budget [TeamPlanning::Budget::Report, nil] the scenario's budget, read as the viewer; nil for the
  #   root, which has no period, and for a scenario with no budget lines, which has no budget to check
  # @param structures [TeamPlanning::PlannedStructures, nil] the unit types in force at each unit, and where each may sit; nil checks no fit
  def initialize(map, changes, left_ids: [], closed_units: {}, unclassified: [], priced: [], budget: nil, structures: nil, today: Date.current)
    @map = map
    @structures = structures
    @today = today
    @budget = budget
    @position_units = closed_units.merge(map.positions.to_h { [ it.id, it.unit_id ] })
    @unclassified = unclassified
    @priced = priced
    @changes = changes
    @left = left_ids.to_set
    @order = changes.keys.each_with_index.to_h
    @live = map.units.to_set(&:id)
    @retired = map.retired_units.to_set(&:id)
    @outside = map.outside_ids
    @roots = map.scope_ids.to_a.to_set
    @cut = map.cut_positions.to_set(&:id)
  end

  # @return [Array<Item>] in {CHECKS} order, then by subject id and reason
  def call = CHECKS.flat_map { |check| send(check).sort_by { [ it.subject_id, it.reason ] }.map { it.with(check:) } }

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

  # A target start the calendar has passed while part of the seat is still
  # open, so the plan's figures count someone who hasn't started
  # ([#458](https://github.com/espaliahq/espalia/issues/458)).
  def late_hires
    TeamPlanning::SeatStart.openings(@map).group_by(&:first).filter_map do |position, parts|
      late = parts.sum(0r) { |_, open, start| start.basis == "target" && start.planned < @today ? open : 0r }
      next unless late.positive?

      item(position.id, POSITION, "Its target start, #{position.target_start.strftime('%-d %b %Y')}, has passed with #{fte(late)} FTE still open")
    end
  end

  # A root of a scoped plan sits under a unit the plan doesn't cover, so that
  # parent is never gone. Once the plan puts the root under a unit the
  # scenario retires, its parent is one the plan covers, and gone like any.
  def units
    parted = @map.units.filter_map do |unit|
      next if unit.parent_id.nil? || @live.include?(unit.parent_id) || (@roots.include?(unit.id) && !@retired.include?(unit.parent_id))

      item(unit.id, UNIT, "Its parent is #{gone(unit.parent_id)}", broken_by: [ [ unit.parent_id, UNIT ] ])
    end
    parted + (@roots - @live - @retired).map { item(it, UNIT, "The plan covers it, but the organisation no longer has it") }
  end

  # A unit type's rules can narrow after the plan placed a unit, so the plan
  # marks the unit instead of refusing what it already holds. It reads the
  # resolved map, which a scoped plan has cut to its units. A root of that
  # scope sits under a unit the plan doesn't cover, whatever the cut map shows
  # as its parent, so it is judged only once the plan puts it under a unit on
  # the map: never at the top, and never against a unit the plan can't name.
  # A parent gone from the scenario is the units check's. A type that is gone
  # needs no parent to judge. The Org Graph can change a parent's type, so a
  # unit that no longer fits beneath its parent names the parent's unit too,
  # while the change stays the unit's own: a parent's plan change never breaks it.
  def misfits
    return [] unless @structures

    by_id = @map.units.index_by(&:id)
    @map.units.filter_map do |unit|
      parent = unit.parent_id && by_id[unit.parent_id]
      next unless (why = misfit(unit, parent, judged: !((unit.parent_id || @roots.include?(unit.id)) && !parent)))

      beneath = parent && !@structures.declares?(parent.id) && @structures.at(unit.id).kind(@structures.level_of(unit))
      item(unit.id, UNIT, "#{I18n.t('org_graph.misfit')}: #{why}", units: beneath ? [ parent.id ] : [])
    end
  end

  # A unit beneath a declaring parent sits at the top of the parent's
  # structure, so it is judged as a top unit there.
  def misfit(unit, parent, judged:)
    return unless unit.level_id

    taxonomy = @structures.at(unit.id)
    level_id = @structures.level_of(unit)
    return missing_type(level_id) unless (kind = taxonomy.kind(level_id))
    return unless judged
    return ("#{kind.name} can't sit at the top" unless kind.top?) if parent.nil? || @structures.declares?(parent.id)
    return unless (parent_kind = taxonomy.kind(@structures.level_of(parent)))

    "#{kind.name} can't sit under #{parent_kind.name}" unless taxonomy.allows?(kind.id, beneath: parent_kind.id)
  end

  # A type the plan can see in another structure is named; one it can't, or
  # one gone from every structure, reads as gone.
  def missing_type(level_id)
    return "its unit type no longer exists" unless @structures.visible_type?(level_id)

    "its type belongs to another structure"
  end

  def unresolved
    @map.unresolved.map { item(it.person_id, ASSIGNMENT, "Placed, but #{it.why}", fact: "employment_status") }
  end

  # A bring-in undone, or the Org Graph moving someone out, leaves their
  # changes standing on nobody the plan shows (#338). An assignment that
  # places them outside is the plan moving them out, so it stands.
  def uncovered
    @changes.filter_map do |(subject_id, facet), change|
      Item.new(subject_id:, facet:, reason: UNCOVERED, change:) if facet != ASSIGNMENT && @outside.include?(subject_id)
    end
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
  #
  # A scoped plan never names a place outside it, as the map leaves those out.
  def capacity_overrides
    known = @map.known_unit_ids
    in_position = ->(place_id) { @position_units.key?(place_id) && (@position_units[place_id].nil? || known.include?(@position_units[place_id])) }
    outside = ->(place_id) { @map.scope_ids && !known.include?(place_id) && !in_position.(place_id) }
    @map.people.flat_map do |person|
      held = person.memberships.to_set { it.position_id || it.unit_id }
      person.capacity_overrides.keys.reject { held.include?(it) || outside.(it) }.sort.map do |place_id|
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

  def places_of(person) = (person.memberships - @map.outside_places(person)).map { it.position_id ? @position_units[it.position_id] : it.unit_id }

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
      return if @outside.include?(line.person_id)

      manager = by_id[line.person_id]
      return "Their manager is no longer in this scenario" unless manager
      return "Their manager has since left" if @left.include?(manager.id)
      return if nearby.empty?

      UNSHARED.first unless nearby.intersect?(units_of(manager))
    else
      return if @cut.include?(line.position_id)

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

  # An override hides the number, never the reports, so the model's own
  # figure decides. The excess is the whole seat's, so each seat is one item
  # however many places it holds. An open position that people report to is
  # flagged as a filled seat is, so leaving it empty never hides the load.
  def overloaded
    @priced.filter_map do |priced|
      places = priced.places.select { (it.calculated || it.figure)&.overloaded }
      next if places.empty?

      figure = places.first.calculated || places.first.figure
      reports = figure.working.filter_map(&:subject_id).uniq
      reason = "Managing #{pluralize(reports.size, 'report')} costs #{decimal(figure.excess)} more than the seat delivers"
      reason += "; its figure is overridden" if places.any?(&:overridden)
      item(priced.seat.id, CAPACITY, reason, broken_by: overload_causes(priced.seat, reports, places), units: places.map(&:unit_id))
    end
  end

  # The seat's own level and place, a position it fills (whose role picks the
  # model), each report's line to it and level (a report costs more the more
  # junior), and the capacity rule that chose the model can each tip a seat
  # over. A person's level is their own before a position's, so both count,
  # though a report with a level of their own costs the same whatever the
  # position they fill.
  def overload_causes(seat, report_ids, places)
    filled = places.filter_map { it.place.position_id }
    own = seat.kind == "person" ? [ [ seat.id, ASSIGNMENT ], *level_keys(seat.id, filled) ] : [ [ seat.id, POSITION ] ]
    positions = @map.positions.to_set(&:id)
    own_level = @own_level_ids ||= @priced.select(&:own_level).to_set { it.seat.id }
    reports = report_ids.flat_map do
      next [ [ it, POSITION ] ] if positions.include?(it)

      [ [ it, LINE ], [ it, ASSIGNMENT ], *level_keys(it, ([] if own_level.include?(it))) ]
    end
    rules = places.filter_map { effective_rule(it.unit_id) }
    [ *own, *reports, *rules ].uniq
  end

  def level_keys(person_id, position_ids = nil)
    position_ids ||= (@people_by_id ||= @map.people.index_by(&:id))[person_id]&.memberships.to_a.filter_map(&:position_id)
    [ [ person_id, LEVEL ], *position_ids.map { [ it, POSITION ] } ]
  end

  def decimal(value) = BigDecimal(value, 20).round(4).to_s("F").delete_suffix(".0")

  def pluralize(count, noun) = "#{count} #{count == 1 ? noun : noun.pluralize}"

  # A leaver's backfill carries their seat, a forgotten person's override is
  # gone with them, and a closed position is the placements check's item.
  UNCLASSIFIED_ELSEWHERE = %w[leaving override_unknown closed_position].freeze

  def unclassified
    @unclassified.reject { |_, place| UNCLASSIFIED_ELSEWHERE.include?(place.reason) }.map do |priced, place|
      seat = priced.seat
      facet = "#{CAPACITY}:#{place.place.position_id || place.unit_id || UNASSIGNED}"
      reason = "Counts for no capacity: #{TeamPlanning::Capacity::REASONS.fetch(place.reason).downcase_first}"
      deciding = deciding_rule(place.unit_id) if MODEL_REASONS.include?(place.reason)
      next Item.new(subject_id: seat.id, facet:, reason:, change: @changes[deciding], unit_ids: units_touched(seat.id, facet, [])) if deciding

      item(seat.id, facet, reason, broken_by: unclassified_causes(seat, place))
    end
  end

  # Whether a place has a model is the rule's choice alone, so the plan's
  # rule that decided it is the cause, however late the seat's own change
  # landed. The nearest unit to set the rule decides, then the plan.
  def deciding_rule(unit_id) = effective_rule(unit_id)&.then { it if @changes.key?(it) }

  def effective_rule(unit_id)
    keys = rule_keys(unit_id).select { it.last == CAPACITY_RULE }
    keys.find { |subject_id, _| @map.rules.by_subject.fetch(subject_id, {}).key?(CAPACITY_RULE_NAME) }
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
  MODEL_REASONS = %w[no_model unknown_model].freeze
  CAPACITY_RULE_NAME = TeamPlanning::RuleKinds::Capacity.rule_name
  CAPACITY_RULE = "#{TeamPlanning::Events::RuleSet.facet}:#{CAPACITY_RULE_NAME}".freeze

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

  # A funding stands when its position closes or a line it draws on goes, so name it.
  def fundings
    open = @map.positions.to_set(&:id)
    held = @map.budget_lines.to_set(&:id)
    @map.fundings.flat_map do |position_id, draws|
      next [] if @cut.include?(position_id)
      next [ item(position_id, FUNDING, "Funds a closed position", broken_by: [ [ position_id, POSITION ] ]) ] unless open.include?(position_id)

      gone = draws.map { it[:budget_line_id] }.reject { held.include?(it) }
      gone.empty? ? [] : [ item(position_id, FUNDING, "Draws on a budget line this scenario no longer holds", broken_by: gone.map { [ it, BUDGET_LINE ] }) ]
    end
  end

  # A held position no line matches. A share left unfunded only by a removed
  # line is the fundings check's, and a tie is ambiguous_funding's.
  def unfunded
    funded_positions.select { it.reason == "no_line" }.map do |funded|
      item(funded.position.id, FUNDING, "No budget line matches it", broken_by: [ [ funded.position.id, POSITION ] ])
    end
  end

  def ambiguous_funding
    funded_positions.select { it.reason == "ambiguous" }.map do |funded|
      count = funded.matching_ids.size
      item(funded.position.id, FUNDING, "#{count} budget lines could fund it equally, and no funding is set", broken_by: [ [ funded.position.id, POSITION ] ])
    end
  end

  # A seat held some of the period that ends with no cost centre: no label,
  # real value or entry gives it one. A plan where no line and no seat has a
  # cost centre uses none.
  def unplaced
    return [] unless @budget && (@budget.lines.any? { it.line.cost_centre.present? } || @budget.seats.any? { it.cost_centre.present? })

    @budget.seats.select { it.cost_centre.blank? && it.days.positive? }.group_by { [ it.kind, it.seat_id ] }.values.map do |seats|
      seat = seats.first
      if seat.kind == "person"
        item(seat.seat_id, ASSIGNMENT, "Has no cost centre: no position label, cost centre of their own or entry gives one", units: seats.map(&:unit_id))
      else
        item(seat.position_id, POSITION, "Has no cost centre: no label, occupant or entry gives one")
      end
    end
  end

  # A person whose cost centre disagrees with something else that names one
  # ([#421](https://github.com/espaliahq/espalia/issues/421)): the entries
  # that match them, while they keep their real one; their position, by its
  # label or the occupant who decides it; or a budget line their position
  # draws on that names a third. The cost read keeps the value it gives, so
  # this only names the disagreement, once each.
  def cost_centre_mismatches
    return [] unless @budget

    positions = funded_positions.index_by { it.position.id }
    lines = @budget.lines.to_h { [ it.line.id, it.line ] }
    @budget.seats.select { it.kind == "person" && it.cost_centre.present? && it.days.positive? }.group_by(&:seat_id).flat_map do |person_id, seats|
      seats.flat_map { |seat| mismatches_of(seat, positions[seat.position_id], lines).map { [ seat.cost_centre, *it ] } }
           .group_by { |costed, other, _| [ costed, other ] }.map do |(costed, other), found|
        item(person_id, ASSIGNMENT, "Costed in #{costed}, while #{other}", broken_by: found.flat_map(&:last).uniq,
                                                                          units: seats.select { it.cost_centre == costed }.map(&:unit_id))
      end
    end
  end

  # Whether a line's period meets any of the days the seat is held, as {TeamPlanning::Budget} funds it
  def covers?(budget_line, seat) = budget_line && budget_line.starts_on <= seat.held.end && budget_line.ends_on >= seat.held.begin

  # @return [Array<(String, Array)>] each disagreement with the changes that could explain it
  def mismatches_of(seat, funded, lines)
    position_id = funded&.position&.id
    found = [ ([ "the cost centre entries give #{seat.rule_cost_centre}", [] ] if seat.rule_cost_centre) ]
    own = funded&.cost_centre&.cost_centre
    found << [ "their position is in #{own}", [ [ position_id, POSITION ] ] ] if own.present? && own != seat.cost_centre
    held = funded ? funded.draws.select { it.held && covers?(lines[it.budget_line_id], seat) } : []
    held.each do |draw|
      third = lines[draw.budget_line_id].cost_centre.presence
      next if third.nil? || [ seat.cost_centre, own ].include?(third)

      found << [ "their position draws on a budget line for #{third}", [ [ position_id, FUNDING ], [ draw.budget_line_id, BUDGET_LINE ] ] ]
    end
    found.compact
  end

  # A line, cost centre or the whole budget over what it approves, at the
  # strictness rule's scope, as the budget read judges it. Never a money figure.
  def budget_variance
    return [] unless @budget

    lines = @budget.lines.filter_map { |line| over_item(line.line.id, BUDGET_LINE, line.over) }
    centres = @budget.cost_centres.filter_map { |name, totals| over_item(name || NO_COST_CENTRE, COST_CENTRE, totals.over) }
    lines + centres + [ over_item(@map.rules.plan_id, BUDGET, @budget.totals.over) ].compact
  end

  # A line two positions tie on is ambiguous_funding's to fix, so it is not unused.
  def unused_budget_lines
    return [] unless @budget

    drawn = @budget.funding.by_line.keys.to_set | funded_positions.flat_map(&:matching_ids)
    period = @budget.period
    @budget.lines.select { |line| line.line.starts_on <= period.end && line.line.ends_on >= period.begin }
           .reject { drawn.include?(it.line.id) }.map do |line|
      item(line.line.id, BUDGET_LINE, "Nothing in this scenario draws on it")
    end
  end

  def funded_positions = @budget ? @budget.funding.positions : []

  def over_item(subject_id, facet, over, broken_by: [])
    return unless over && (over.money.present? || over.heads)

    parts = [ ("over its approved amount" if over.money.present?), ("over its head count by #{fte(over.heads_by)} FTE" if over.heads) ].compact
    item(subject_id, facet, "Spends #{parts.join(' and ')}", broken_by:)
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
    when POSITION, FUNDING then [ @position_units[subject_id] ]
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

  def fte(value) = value.to_r.round(4).to_f.to_s.delete_suffix(".0")
end
