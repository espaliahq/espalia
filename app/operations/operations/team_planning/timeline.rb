# frozen_string_literal: true

# One path of a plan along the calendar, read as {TeamPlanning::Timeline}
# lays it out ([#289](https://github.com/espaliahq/espalia/issues/289)). The
# rules a screen inherits, for blocks, lanes, moves and backfills, live on
# that class. Walked by the privacy test and the forgotten-person audit.
class Operations::TeamPlanning::Timeline < Operations::Base
  include Operations::TeamPlanning::PlanRead
  include Operations::TeamPlanning::MapPayload

  description "Get one path of a Team Planning plan the caller is in, from the baseline to a scenario, laid out " \
              "along the calendar. columns are the steps, root first, each with its name, period and " \
              "alternative_ids: the 'instead' scenarios that could stand in that step's place. next_ids are the " \
              "'then' scenarios after the last step. blocks are units, one per unit across the columns it lives " \
              "in (a rename or a one-to-one succession keeps the block), with units per column (null where it " \
              "doesn't live), continues_from_ids for a split or merge, and lane_ids in order. A lane is one head: " \
              "a person while they are on the map, a position's bars while it stands empty, a backfill in the " \
              "lane of the person it replaces, and the first hire into a position in that position's lane. Bars " \
              "give the columns a place is held (from and to are column indexes); a unit_id of null is " \
              "Unassigned, listed in unassigned_lane_ids. A person's bar carries shares, their share of their time in " \
              "that place in each of its columns, counting every place they hold as the map does. moves name the units a person left and joined after a " \
              "column (crossing is \"out\" when they leave the units a scoped plan covers and \"in\" when they join them), and departures the column they leave in, with its backfill. " \
              "Each column's movable lists the places, positions and departures that step itself changes, as subject_id and facet: " \
              "what team_planning_move_change can move a step earlier or later. walk counts the plan's heads in each column, " \
              "and each block's walk and unassigned_walk the heads in that block and in Unassigned: opening (the last column's " \
              "closing), hires (new to the map), transfers_in (from another unit, or from outside a scoped plan's units), " \
              "departures, transfers_out and closing, which is opening plus hires and transfers_in less departures and " \
              "transfers_out. Heads, not FTE: a person in two units is one head in each and one in the plan. The first " \
              "column, today, has a closing only. positions are keyed by id, each as " \
              "it stands in the last column it appears in. `names` maps every person id " \
              "to a name; a forgotten person reads as \"#{Person::FORMER_MEMBER}\". Refused, as an unknown plan, " \
              "unless the caller is a member."
  category :read
  approval :none

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true, schema: { description: "The last step, or the plan's id for the baseline alone." }

  # @return [Hash] `{ plan_id, scenario_id, columns, next_ids, walk, blocks, unassigned_lane_ids, unassigned_walk, lanes, positions, names }`
  def perform
    plan = plan!
    scenario_id = scenario_id!(:scenario_id)
    timeline = refusing_bad_plans { ::TeamPlanning::Timeline.new(context:, plan:, scenario_id:).call }
    { plan_id: plan.id, scenario_id:, columns: columns(plan, timeline), next_ids: timeline.next_ids, walk: timeline.walk.map(&:to_h),
      blocks: blocks(timeline), unassigned_lane_ids: timeline.unassigned_lane_ids, unassigned_walk: timeline.unassigned_walk.map(&:to_h),
      lanes: timeline.lanes.map { lane(it) }, positions: positions(timeline),
      names: timeline.maps.map { names_for(it) }.reduce({}, :merge) }
  end

  private

  def columns(plan, timeline)
    ids = timeline.columns.map(&:scenario_id)
    rows = TeamPlanningScenario.where(plan_id: plan.id, id: ids).index_by(&:id)
    movable = TeamPlanningOverride.where(scenario_id: ids, facet: ::TeamPlanning::PlanAggregate::MOVABLE_FACETS)
                                  .order(:subject_id, :facet).pluck(:scenario_id, :subject_id, :facet)
                                  .group_by(&:first)
    timeline.columns.map do |column|
      row = rows.fetch(column.scenario_id)
      { scenario_id: column.scenario_id, name: row.name&.reveal, starts_on: row.starts_on.iso8601, ends_on: row.ends_on&.iso8601,
        alternative_ids: column.alternative_ids,
        movable: movable.fetch(column.scenario_id, []).map { |_, subject_id, facet| { subject_id:, facet: } } }
    end
  end

  def blocks(timeline)
    timeline.blocks.map do |block|
      units = block.unit_ids.zip(timeline.maps).map do |unit_id, map|
        unit_id && { unit_id:, name: map.units.find { it.id == unit_id }.name }
      end
      { block_id: block.id, units:, continues_from_ids: block.continues_from_ids, lane_ids: block.lane_ids, walk: block.walk.map(&:to_h) }
    end
  end

  def lane(lane)
    { lane_id: lane.id, bars: lane.bars.map(&:to_h), moves: lane.moves.map { it.crossing ? it.to_h : it.to_h.except(:crossing) },
      departures: lane.departures.map(&:to_h) }
  end

  def positions(timeline)
    timeline.maps.flat_map { positions_payload(it) }.to_h { [ it[:position_id], it.except(:position_id) ] }
  end
end
