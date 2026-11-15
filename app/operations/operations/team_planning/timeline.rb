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
              "column, and departures the column they leave in, with its backfill. positions are keyed by id, each as " \
              "it stands in the last column it appears in. `names` maps every person id " \
              "to a name; a forgotten person reads as \"#{Person::FORMER_MEMBER}\". Refused, as an unknown plan, " \
              "unless the caller is a member."
  category :read
  approval :none

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true, schema: { description: "The last step, or the plan's id for the baseline alone." }

  # @return [Hash] `{ plan_id, scenario_id, columns, next_ids, blocks, unassigned_lane_ids, lanes, positions, names }`
  def perform
    plan = plan!
    scenario_id = scenario_id!(:scenario_id)
    timeline = refusing_bad_plans { ::TeamPlanning::Timeline.new(context:, plan:, scenario_id:).call }
    { plan_id: plan.id, scenario_id:, columns: columns(plan, timeline), next_ids: timeline.next_ids,
      blocks: blocks(timeline), unassigned_lane_ids: timeline.unassigned_lane_ids,
      lanes: timeline.lanes.map { lane(it) }, positions: positions(timeline),
      names: timeline.maps.map { names_for(it) }.reduce({}, :merge) }
  end

  private

  def columns(plan, timeline)
    rows = TeamPlanningScenario.where(plan_id: plan.id, id: timeline.columns.map(&:scenario_id)).index_by(&:id)
    timeline.columns.map do |column|
      row = rows.fetch(column.scenario_id)
      { scenario_id: column.scenario_id, name: row.name&.reveal, starts_on: row.starts_on.iso8601, ends_on: row.ends_on&.iso8601,
        alternative_ids: column.alternative_ids }
    end
  end

  def blocks(timeline)
    timeline.blocks.map do |block|
      units = block.unit_ids.zip(timeline.maps).map do |unit_id, map|
        unit_id && { unit_id:, name: map.units.find { it.id == unit_id }.name }
      end
      { block_id: block.id, units:, continues_from_ids: block.continues_from_ids, lane_ids: block.lane_ids }
    end
  end

  def lane(lane)
    { lane_id: lane.id, bars: lane.bars.map(&:to_h), moves: lane.moves.map(&:to_h),
      departures: lane.departures.map(&:to_h) }
  end

  def positions(timeline)
    timeline.maps.flat_map { positions_payload(it) }.to_h { [ it[:position_id], it.except(:position_id) ] }
  end
end
