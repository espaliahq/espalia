# frozen_string_literal: true

# Moves one of a person's places in a scenario, the way the scenario map's
# drag and "Move…" do [#285](https://github.com/espaliahq/espalia/issues/285).
# It reads the person's places from the resolved map, swaps the one named for
# the new one, and writes the whole list through {SetAssignment}, so the change
# is an ordinary AssignmentSet. A place the HRIS gave no allocation is written
# with the share {TeamPlanning::Baseline::Membership.shares} reads it as.
#
# The baseline is Today and is refused here, whatever the caller: the map
# edits a scenario, never the Org Graph's own picture.
class Operations::TeamPlanning::MovePlace < Operations::Base
  include Operations::TeamPlanning::PlanWrite

  UNASSIGNED = "unassigned"

  description "Move one of a person's places in a scenario of a Team Planning plan to another unit, or to " \
              "Unassigned, keeping their other places. from_unit_id names the place: a unit, with " \
              "from_position_id for a place in a position, or 'unassigned' for a person in no live unit. " \
              "to_unit_id is the unit they move to, or 'unassigned' to drop the place. allocation (above 0, at " \
              "most 1) and role describe the new place; a place they already hold in that unit is replaced. " \
              "Written as one AssignmentSet. Refused on the baseline, and unless the caller is one of the plan's editors."
  category :write
  approval :mcp_client

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true, schema: { description: "A scenario of the plan. Not the baseline." }
  parameter :person_id, String, required: true
  parameter :from_unit_id, String, required: true, schema: { description: "The unit the place is in, or 'unassigned'." }
  parameter :from_position_id, String, schema: { description: "The position the place is in, when it is in one." }
  parameter :to_unit_id, String, required: true, schema: { description: "The unit to move to, or 'unassigned'." }
  parameter :allocation, Numeric, schema: { exclusiveMinimum: 0, maximum: 1,
                                            description: "The new place's allocation. Required unless moving to 'unassigned'." }
  parameter :role, String, schema: { description: "The person's role in the new place, such as Lead." }

  # @return [Hash] `{ plan_id, scenario_id, person_id, placements }`
  def perform
    editor_scenario!
    map = Operations::TeamPlanning::ScenarioMap.call(context:, params: { plan_id: plan_id!, scenario_id: })
    person = map[:people].find { it[:id] == person_id } or raise Operations::Base::ParameterError, "This scenario has no such person"

    Operations::TeamPlanning::SetAssignment.call(
      context:, params: { plan_id: plan_id!, scenario_id:, person_id:, placements: placements(person, map) }
    )
  end

  private

  def editor_scenario!
    plan = Operations::TeamPlanning::Plan.call(context:, params: { plan_id: plan_id! })
    raise Operations::Base::ParameterError, "No such plan" unless plan[:role] == "editor"
    raise Operations::Base::ParameterError, "Today can't be edited. Fork a scenario and edit that." if scenario_id == plan[:plan_id]
  end

  def scenario_id = scenario_id!(:scenario_id)

  def person_id = uuid!(:person_id)

  def placements(person, map)
    live = map[:units].to_set { it[:id] }
    held = ::TeamPlanning::Baseline::Membership.shares(person[:memberships].map { ::TeamPlanning::Baseline::Membership.new(**it) })
    moved, kept = held.partition { |place, _, _| from?(place, live) }
    raise Operations::Base::ParameterError, "#{map[:names][person_id]} holds no such place" if moved.empty? && from_unit != UNASSIGNED

    kept.reject! { |place, _, _| place.position_id.nil? && place.unit_id == to_unit }
    kept.map { |place, share, _| written(place, share) } + arriving
  end

  def from?(place, live)
    return !live.include?(place.unit_id) if from_unit == UNASSIGNED

    place.unit_id == from_unit && place.position_id == params[:from_position_id].presence
  end

  def written(place, share)
    raise Operations::Base::ParameterError, "A place with no allocation has nothing left to share. Set its allocation first." unless share.positive?

    spot = place.position_id ? { position_id: place.position_id } : { unit_id: place.unit_id }
    { **spot, allocation: share.to_f, role: place.role }.compact
  end

  def arriving
    return [] if to_unit == UNASSIGNED
    raise Operations::Base::ParameterError, "allocation is required" if params[:allocation].nil?

    [ { unit_id: to_unit, allocation: params[:allocation].to_f, role: params[:role].presence }.compact ]
  end

  def from_unit = unit_param(:from_unit_id)

  def to_unit = unit_param(:to_unit_id)

  def unit_param(name) = params[name] == UNASSIGNED ? UNASSIGNED : uuid!(name)
end
