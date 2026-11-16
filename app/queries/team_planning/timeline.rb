# frozen_string_literal: true

# One path through a plan's scenarios, from the baseline to a scenario, laid
# out as the timeline draws it: a column per step, units as blocks, a lane
# per head, and the moves between columns. The baseline is read once, each
# step resolved over it as the map resolves it ({TeamPlanning::Resolution}),
# and nothing is stored.
#
# The rules the screen inherits:
#
# - A unit is one block across the columns it lives in, renamed or not. A
#   unit that carries on from exactly one other, by a recorded succession,
#   continues that unit's block; a split or a merge links blocks instead.
# - A lane belongs to a person and lasts while they are on the map, placed or
#   not. Holding two places at once is two bars in one lane.
# - Where a person leaves a unit and joins another from one column to the
#   next, the lane records a move naming both sides. Taking on or dropping a
#   second place is no move, and nor is carrying on into a unit's successor in
#   the same block. A nil unit is Unassigned: placed in no live unit.
# - A leaver's lane ends in the step they leave in, and the position that
#   backfills them carries on in it. A new position takes no one's lane, and
#   the first person to fill it takes its lane, so a seat and its hire read
#   as one head.
# - A position's bar runs while it stands empty.
# - A walk counts heads, not FTE: a person in two units is one head in each,
#   and one in the plan. Opening is the last column's closing. Someone new to
#   the map is a hire; someone who arrives from another unit, or from outside a
#   scoped plan's units, transfers in. A leaver departs in the step they leave
#   in, so closing is opening, plus hires and transfers in, less departures and
#   transfers out. The first column, today, has a closing only.
# - Blocks come in the order they first appear, then as the map orders units.
#   Lanes in a block come in the order they first appear there, people
#   before positions, then by name and id.
#
# @example
#   TeamPlanning::Timeline.new(context:, plan:, scenario_id: q2).call
class TeamPlanning::Timeline
  # A step of the path, and the scenarios that could stand in its place.
  Column = Data.define(:scenario_id, :alternative_ids)

  # A run of columns, from `from` to `to`, where a head holds one place.
  # `kind` is "person" or "position"; `unit_id` is nil for Unassigned.
  # `shares` gives a person's share of their time in this place for each
  # column, counting places in retired units too, as the map does.
  Bar = Data.define(:kind, :subject_id, :from, :to, :unit_id, :position_id, :allocation, :role, :replaces_id, :shares)

  # Between column `after` and the next, the units a person left and joined.
  # `crossing` is "out" when they leave the units a scoped plan covers, with
  # no units joined, and "in" when they join them, with none left.
  Move = Data.define(:person_id, :after, :left_unit_ids, :joined_unit_ids, :crossing) do
    def initialize(crossing: nil, **) = super
  end

  # A person leaving in column `column`, and the position backfilling them.
  Departure = Data.define(:person_id, :column, :position_id)

  # One head along the path.
  Lane = Data.define(:id, :bars, :moves, :departures)

  # A unit's run along the path, by the unit it held in each column.
  # `continues_from_ids` names the blocks a split or merge carries on from.
  # `walk` counts its heads in each column, as the plan's walk does.
  Block = Data.define(:id, :unit_ids, :continues_from_ids, :lane_ids, :walk)

  # The heads in a column: how many it opened with, arrived, left and closed with.
  Walk = Data.define(:opening, :hires, :transfers_in, :departures, :transfers_out, :closing)

  # @!attribute columns [Array<Column>] root first
  # @!attribute next_ids [Array<String>] the scenarios that follow the last step
  # @!attribute maps [Array<TeamPlanning::Baseline::Map>] each column's map, named
  # @!attribute blocks [Array<Block>]
  # @!attribute unassigned_lane_ids [Array<String>] lanes with a bar in no live unit
  # @!attribute lanes [Array<Lane>]
  # @!attribute walk [Array<Walk>] the plan's heads, per column
  # @!attribute unassigned_walk [Array<Walk>] the heads placed in no live unit, per column
  Result = Data.define(:columns, :next_ids, :maps, :blocks, :unassigned_lane_ids, :lanes, :walk, :unassigned_walk)

  # @param context [AuthorizationContext]
  # @param plan [TeamPlanningPlan]
  # @param scenario_id [String] the last step; the plan's id for the baseline alone
  # @param repository [TeamPlanning::Repository]
  def initialize(context:, plan:, scenario_id:, repository: TeamPlanning::Repository.new)
    @context = context
    @plan = plan
    @scenario_id = scenario_id
    @repository = repository
  end

  # @return [Result]
  # @raise [Pundit::NotAuthorizedError] when the caller can't open the plan or see the Org Graph
  # @raise [TeamPlanning::Error] for a scenario the plan doesn't have
  def call
    aggregate = @repository.load_plan(@plan.id)
    path = aggregate.timeline_path(@scenario_id)
    baseline = TeamPlanning::Baseline.new(context: @context, plan: @plan)
    base = baseline.structure
    maps = path.map do |scenario_id|
      baseline.named(TeamPlanning::Resolution.new(context: @context, plan: @plan, scenario_id:, repository: @repository, base:).structure(aggregate))
    end
    Layout.new(maps).result(columns: columns(aggregate, path), next_ids: next_ids(aggregate, path.last))
  end

  private

  def columns(aggregate, path)
    path.each_with_index.map do |scenario_id, index|
      Column.new(scenario_id:, alternative_ids: index.zero? ? [] : alternatives(aggregate, path.first(index), scenario_id))
    end
  end

  # Either half of a split step is part of the step, not another way through it.
  def alternatives(aggregate, before, scenario_id)
    @paths ||= aggregate.scenarios.keys.index_with { aggregate.timeline_path(it) }
    same_step = [ scenario_id, *aggregate.resting_on(scenario_id) ]
    ordered(@paths.keys).select { same_step.exclude?(it) && @paths[it] == before + [ it ] && aggregate.resting_on(it).empty? }
  end

  def next_ids(aggregate, scenario_id)
    ordered(aggregate.scenarios.select { |_, scenario| scenario.parent_id == scenario_id && follows?(scenario.relation) }.keys)
  end

  def follows?(relation)
    case relation
    in "then" then true
    in "instead" | "on" then false
    end
  end

  def ordered(ids) = ids.sort_by { [ created_order.fetch(it, created_order.size), it ] }

  def created_order
    @created_order ||= TeamPlanningScenario.where(plan_id: @plan.id).order(:created_at, :id).pluck(:id).each_with_index.to_h
  end

  # Lays the resolved maps out as blocks and lanes.
  class Layout
    # @param maps [Array<TeamPlanning::Baseline::Map>] one per column, named
    def initialize(maps)
      @maps = maps
      @names = maps.map(&:names).reduce({}, :merge)
      @block_of = block_ids
    end

    # @return [Result]
    def result(columns:, next_ids:)
      lane_of = lane_owners
      lanes = lanes(lane_of)
      Result.new(columns:, next_ids:, maps: @maps, blocks: blocks(lanes), unassigned_lane_ids: lane_ids_in(lanes, nil),
                 lanes: lanes.sort_by { lane_order(it, it.bars) }, walk: walk(@maps.map { it.people.to_set(&:id) }),
                 unassigned_walk: block_walk(nil))
    end

    private

    def successions = @maps.flat_map(&:successions).uniq(&:id)

    # A unit that carries on from exactly one other joins that one's block,
    # unless the two ever stand side by side: one absorbing a unit that
    # already existed keeps its own.
    def block_ids
      parent = successions.select { it.predecessor_ids.one? && it.successor_ids.one? }
                          .to_h { [ it.successor_ids.first, it.predecessor_ids.first ] }
                          .reject { |successor, predecessor| side_by_side?(successor, predecessor) }
      root = ->(id, seen = Set[]) { parent.key?(id) && seen.add?(id) ? root.call(parent[id], seen) : id }
      @maps.flat_map { it.units.map(&:id) }.uniq.index_with { root.call(it) }
    end

    def side_by_side?(*unit_ids) = @maps.any? { |map| unit_ids.all? { |id| map.units.any? { it.id == id } } }

    def blocks(lanes)
      first_seen = {}
      @maps.each_with_index do |map, column|
        map.units.each_with_index { |unit, rank| first_seen[@block_of[unit.id]] ||= [ column, rank, @block_of[unit.id] ] }
      end
      first_seen.values.sort.map do |_, _, block_id|
        Block.new(id: block_id, unit_ids: @maps.map { |map| map.units.find { @block_of[it.id] == block_id }&.id },
                  continues_from_ids: continues_from(block_id), lane_ids: lane_ids_in(lanes, block_id), walk: block_walk(block_id))
      end
    end

    def block_walk(block_id) = walk(heads_by_block.map { it.fetch(block_id, Set[]) })

    def heads_by_block
      @heads_by_block ||= @maps.map do |map|
        map.people.each_with_object({}) do |person, heads|
          units_of(map, person).each { (heads[block_for(it)] ||= Set[]) << person.id }
        end
      end
    end

    # @param heads [Array<Set<String>>] the people counted, per column
    def walk(heads)
      heads.each_with_index.map do |now, column|
        closing = (now - leaving_ids[column]).size
        next Walk.new(opening: nil, hires: nil, transfers_in: nil, departures: nil, transfers_out: nil, closing:) if column.zero?

        opened = heads[column - 1] - leaving_ids[column - 1]
        arrived, gone = now - opened, opened - now
        hires = (arrived - held_ids[column - 1]).size
        Walk.new(opening: opened.size, hires:, transfers_in: arrived.size - hires,
                 departures: ((now | gone) & leaving_ids[column]).size, transfers_out: (gone - leaving_ids[column]).size, closing:)
      end
    end

    # A leaver the same step takes outside a scoped plan is in `outside`, and still leaves.
    def leaving_ids = @leaving_ids ||= @maps.map { |map| (map.people + map.outside).select(&:leaving?).to_set(&:id) }

    def held_ids = @held_ids ||= @maps.map { |map| map.people.to_set(&:id) | map.outside_ids }

    def continues_from(block_id)
      successions.select { |succession| succession.successor_ids.any? { @block_of[it] == block_id } }
                 .flat_map { |succession| succession.predecessor_ids.filter_map { @block_of[it] } }.uniq - [ block_id ]
    end

    def lane_ids_in(lanes, block_id)
      lanes.filter_map do |lane|
        bars = lane.bars.select { block_for(it.unit_id) == block_id }
        [ lane_order(lane, bars), lane.id ] if bars.any?
      end.sort.map(&:last)
    end

    def block_for(unit_id) = unit_id && @block_of[unit_id]

    def lane_order(lane, bars)
      first = bars.min_by { [ it.from, it.kind == "person" ? 0 : 1 ] }
      [ first.from, first.kind == "person" ? 0 : 1, first.kind == "person" ? @names.fetch(first.subject_id, "") : "", lane.id ]
    end

    # Which lane each person and position runs in, column by column so a
    # hire is in their seat's lane before a backfill for them looks it up.
    # Someone who first appears filling a position that stood empty earlier
    # takes its lane, one hire per seat; a backfill runs in its leaver's lane.
    def lane_owners
      owner = {}
      taken = Set[]
      @maps.each_with_index do |map, column|
        map.people.each do |person|
          next if owner.key?(person.id)

          seat = person.memberships.filter_map(&:position_id).find { (opened = position_column[it]) && opened < column && !taken.include?(it) }
          owner[person.id] = seat ? owner.fetch(seat).tap { taken << seat } : person.id
        end
        map.positions.each do |position|
          owner[position.id] ||= (leaver = replaces[position.id]) ? owner.fetch(leaver, leaver) : position.id
        end
      end
      owner
    end

    def position_column
      @position_column ||= @maps.each_with_index.with_object({}) do |(map, column), first|
        map.positions.each { first[it.id] ||= column }
      end
    end

    # The person each backfill replaces, the first it names where it first does.
    def replaces
      @replaces ||= @maps.each_with_object({}) do |map, first|
        map.backfills.each { |position_id, ids| first[position_id] ||= ids.first }
      end
    end

    def lanes(lane_of)
      bars = person_bars + position_bars
      by_lane = bars.group_by { lane_of.fetch(it.subject_id, it.subject_id) }
      moves = person_moves.group_by { lane_of.fetch(it.person_id, it.person_id) }
      departures = person_departures.group_by { lane_of.fetch(it.person_id, it.person_id) }
      by_lane.map do |id, lane_bars|
        Lane.new(id:, bars: lane_bars.sort_by { [ it.from, it.kind == "person" ? 0 : 1, it.unit_id.to_s, it.position_id.to_s ] },
                 moves: moves.fetch(id, []), departures: departures.fetch(id, []))
      end
    end

    def person_bars
      places = @maps.map do |map|
        live = map.units.to_set(&:id)
        map.people.to_h do |person|
          held = person.memberships.select { live.include?(it.unit_id) }
          [ person.id, held.empty? ? [ [ nil, nil, nil, nil ] ] : held.map { place_key(it) } ]
        end
      end
      runs(places) do |person_id, key, from, to|
        unit_id, position_id, allocation, role = key
        shares = unit_id && (from..to).map { person_shares[it].dig(person_id, key)&.to_f }
        Bar.new(kind: "person", subject_id: person_id, from:, to:, unit_id:, position_id:, allocation:, role:, replaces_id: nil, shares:)
      end
    end

    def person_shares
      @person_shares ||= @maps.map do |map|
        map.people.to_h do |person|
          [ person.id, TeamPlanning::Baseline::Membership.shares(person.memberships).to_h { |membership, share, _| [ place_key(membership), share ] } ]
        end
      end
    end

    def place_key(membership) = [ membership.unit_id, membership.position_id, membership.allocation, membership.role ]

    def position_bars
      places = @maps.map do |map|
        filled = map.occupants
        live = map.units.to_set(&:id)
        map.positions.select { filled.fetch(it.id, []).empty? && live.include?(it.unit_id) }.to_h { [ it.id, [ [ it.unit_id, it.id, nil, nil ] ] ] }
      end
      runs(places) do |position_id, (unit_id, _, _, _), from, to|
        Bar.new(kind: "position", subject_id: position_id, from:, to:, unit_id:, position_id:, allocation: nil, role: nil,
                replaces_id: replaces[position_id], shares: nil)
      end
    end

    # @param places [Array<Hash{String => Array}>] per column, subject => the places it holds
    def runs(places)
      open = {}
      bars = []
      places.each_with_index do |held, column|
        held.each do |subject_id, keys|
          keys.each do |key|
            run = open[[ subject_id, key ]]
            run && run[:to] == column - 1 ? run[:to] = column : open[[ subject_id, key ]] = (bars << { subject_id:, key:, from: column, to: column }).last
          end
        end
      end
      bars.map { yield it[:subject_id], it[:key], it[:from], it[:to] }
    end

    def person_moves
      @maps.each_cons(2).each_with_index.flat_map do |(before, after), column|
        later = after.people.index_by(&:id)
        crossings(before, after, column) + before.people.filter_map do |person|
          next unless (next_person = later[person.id])

          was = units_of(before, person)
          now = units_of(after, next_person)
          left = was.reject { |unit_id| now.any? { block_for(it) == block_for(unit_id) } }
          joined = now.reject { |unit_id| was.any? { block_for(it) == block_for(unit_id) } }
          next if left.empty? || joined.empty?

          Move.new(person_id: person.id, after: column, left_unit_ids: left, joined_unit_ids: joined)
        end
      end
    end

    def crossings(before, after, column)
      leaving, joining = after.outside_ids, before.outside_ids
      out = before.people.select { leaving.include?(it.id) }.map do |person|
        Move.new(person_id: person.id, after: column, left_unit_ids: units_of(before, person), joined_unit_ids: [], crossing: "out")
      end
      out + after.people.select { joining.include?(it.id) }.map do |person|
        Move.new(person_id: person.id, after: column, left_unit_ids: [], joined_unit_ids: units_of(after, person), crossing: "in")
      end
    end

    def units_of(map, person)
      live = (@live_unit_ids ||= {}.compare_by_identity)[map] ||= map.units.to_set(&:id)
      units = person.memberships.map(&:unit_id).select { live.include?(it) }.uniq.sort
      units.empty? ? [ nil ] : units
    end

    def person_departures
      @maps.each_with_index.flat_map do |map, column|
        map.people.select(&:leaving?).map { Departure.new(person_id: it.id, column:, position_id: it.backfill_id) }
      end.uniq(&:person_id)
    end
  end
end
