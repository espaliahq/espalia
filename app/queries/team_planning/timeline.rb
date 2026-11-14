# frozen_string_literal: true

# One path through a plan's scenarios, from the baseline to a scenario, laid
# out as the timeline draws it: a column per step, units as blocks, a lane
# per head, and the moves between columns. Each step is resolved as the map
# resolves it ({TeamPlanning::Resolution}), and nothing is stored.
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
#   second place is no move. A nil unit is Unassigned: placed in no live unit.
# - A leaver's lane ends in the step they leave in, and the position that
#   backfills them carries on in it. A new position takes no one's lane, and
#   the first person to fill it takes its lane, so a seat and its hire read
#   as one head.
# - A position's bar runs while it stands empty.
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
  Bar = Data.define(:kind, :subject_id, :from, :to, :unit_id, :position_id, :allocation, :role, :replaces_id)

  # Between column `after` and the next, the units a person left and joined.
  Move = Data.define(:person_id, :after, :left_unit_ids, :joined_unit_ids)

  # A person leaving in column `column`, and the position backfilling them.
  Departure = Data.define(:person_id, :column, :position_id)

  # One head along the path.
  Lane = Data.define(:id, :bars, :moves, :departures)

  # A unit's run along the path, by the unit it held in each column.
  # `continues_from_ids` names the blocks a split or merge carries on from.
  Block = Data.define(:id, :unit_ids, :continues_from_ids, :lane_ids)

  # @!attribute columns [Array<Column>] root first
  # @!attribute next_ids [Array<String>] the scenarios that follow the last step
  # @!attribute maps [Array<TeamPlanning::Baseline::Map>] each column's map, named
  # @!attribute blocks [Array<Block>]
  # @!attribute unassigned_lane_ids [Array<String>] lanes with a bar in no live unit
  # @!attribute lanes [Array<Lane>]
  # @!attribute names [Hash{String => String}] person id => name, across every column
  Result = Data.define(:columns, :next_ids, :maps, :blocks, :unassigned_lane_ids, :lanes, :names)

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
    maps = path.map { baseline.named(TeamPlanning::Resolution.new(context: @context, plan: @plan, scenario_id: it, repository: @repository).structure(aggregate)) }
    Layout.new(maps).result(columns: columns(aggregate, path), next_ids: next_ids(aggregate, path.last))
  end

  private

  def columns(aggregate, path)
    path.each_with_index.map do |scenario_id, index|
      Column.new(scenario_id:, alternative_ids: index.zero? ? [] : alternatives(aggregate, path.first(index), scenario_id))
    end
  end

  def alternatives(aggregate, before, scenario_id)
    ordered(aggregate.scenarios.keys).select { it != scenario_id && aggregate.timeline_path(it) == before + [ it ] }
  end

  def next_ids(aggregate, scenario_id)
    ordered(aggregate.scenarios.select { |_, scenario| scenario.parent_id == scenario_id && scenario.relation == "then" }.keys)
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
                 lanes: lanes.sort_by { lane_order(it, it.bars) }, names: @names)
    end

    private

    def successions = @maps.flat_map(&:successions).uniq(&:id)

    # A unit that carries on from exactly one other joins that one's block.
    def block_ids
      parent = successions.select { it.predecessor_ids.one? && it.successor_ids.one? }
                          .to_h { [ it.successor_ids.first, it.predecessor_ids.first ] }
      root = ->(id, seen = Set[]) { parent.key?(id) && seen.add?(id) ? root.call(parent[id], seen) : id }
      @maps.flat_map { it.units.map(&:id) }.uniq.index_with { root.call(it) }
    end

    def blocks(lanes)
      first_seen = {}
      @maps.each_with_index do |map, column|
        map.units.each_with_index { |unit, rank| first_seen[@block_of[unit.id]] ||= [ column, rank, @block_of[unit.id] ] }
      end
      first_seen.values.sort.map do |_, _, block_id|
        Block.new(id: block_id, unit_ids: @maps.map { |map| map.units.find { @block_of[it.id] == block_id }&.id },
                  continues_from_ids: continues_from(block_id), lane_ids: lane_ids_in(lanes, block_id))
      end
    end

    def continues_from(block_id)
      successions.reject { it.predecessor_ids.one? && it.successor_ids.one? }
                 .select { |succession| succession.successor_ids.any? { @block_of[it] == block_id } }
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

    # Which lane each person and position runs in. A backfill runs in its
    # leaver's lane; someone who first appears filling a position that stood
    # empty earlier takes the position's lane.
    def lane_owners
      owner = {}
      first_column = {}
      @maps.each_with_index do |map, column|
        map.people.each { first_column[it.id] ||= column; owner[it.id] ||= it.id }
      end
      backfilled = @maps.flat_map { |map| map.backfills.flat_map { |position_id, ids| ids.map { [ position_id, it ] } } }.to_h
      position_columns = {}
      @maps.each_with_index do |map, column|
        map.positions.each do |position|
          position_columns[position.id] ||= column
          owner[position.id] ||= backfilled.key?(position.id) ? owner.fetch(backfilled[position.id], backfilled[position.id]) : position.id
        end
      end
      @maps.each_with_index do |map, column|
        map.people.each do |person|
          next unless first_column[person.id] == column && owner[person.id] == person.id

          seat = person.memberships.filter_map(&:position_id).find { position_columns.fetch(it, column) < column }
          owner[person.id] = owner[seat] if seat
        end
      end
      owner
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
          [ person.id, held.empty? ? [ [ nil, nil, nil, nil ] ] : held.map { [ it.unit_id, it.position_id, it.allocation, it.role ] } ]
        end
      end
      runs(places) do |person_id, (unit_id, position_id, allocation, role), from, to|
        Bar.new(kind: "person", subject_id: person_id, from:, to:, unit_id:, position_id:, allocation:, role:, replaces_id: nil)
      end
    end

    def position_bars
      replaces = @maps.flat_map { |map| map.backfills.to_a }.to_h { |position_id, ids| [ position_id, ids.first ] }
      places = @maps.map do |map|
        filled = map.occupants
        live = map.units.to_set(&:id)
        map.positions.select { filled.fetch(it.id, []).empty? && live.include?(it.unit_id) }.to_h { [ it.id, [ [ it.unit_id, it.id, nil, nil ] ] ] }
      end
      runs(places) do |position_id, (unit_id, _, _, _), from, to|
        Bar.new(kind: "position", subject_id: position_id, from:, to:, unit_id:, position_id:, allocation: nil, role: nil,
                replaces_id: replaces[position_id])
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
        before.people.filter_map do |person|
          next unless (next_person = later[person.id])

          was = units_of(before, person)
          now = units_of(after, next_person)
          next if (was - now).empty? || (now - was).empty?

          Move.new(person_id: person.id, after: column, left_unit_ids: was - now, joined_unit_ids: now - was)
        end
      end
    end

    def units_of(map, person)
      live = map.units.to_set(&:id)
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
