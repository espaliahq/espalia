# frozen_string_literal: true

# Moves one of a person's places in a scenario, the way the scenario map's
# drag and "Move…" do [#285](https://github.com/espaliahq/espalia/issues/285),
# to a unit or into a position. A full position takes them anyway: fit is
# read, never refused, and Attention flags the position as overfilled.
# It reads the person's places from the resolved map, swaps the one named for
# the new one, and writes the whole list through {SetAssignment}, so the change
# is an ordinary AssignmentSet. A place the HRIS gave no allocation is written
# with the share {TeamPlanning::Baseline::Membership.shares} reads it as. Its
# note is the AssignmentSet's, so a move without one leaves none.
#
# The baseline is Today and is refused here, whatever the caller: the map
# edits a scenario, never the Org Graph's own picture.
class Operations::TeamPlanning::MovePlace < Operations::Base
  include Operations::TeamPlanning::ChangeWrite
  include Operations::TeamPlanning::PlanRead

  UNASSIGNED = "unassigned"

  description "Move one of a person's places in a scenario of a Team Planning plan to another unit, or to " \
              "Unassigned, keeping their other places. from_unit_id names the place: a unit, with " \
              "from_position_id for a place in a position, or 'unassigned' for a person in no live unit. " \
              "Give exactly one of to_unit_id or to_position_id; giving both or neither is refused. to_unit_id " \
              "is the unit they move to, or 'unassigned' to drop the place; to_position_id instead places them " \
              "in a position, even a full one, which the scenario then reports as overfilled. " \
              "allocation (above 0, at most 1) and role describe the new place; a place they already hold in " \
              "that unit, or in that position, is replaced. " \
              "Written as one AssignmentSet. Refused on the baseline, and unless the caller is one of the plan's editors."
  category :write
  approval :mcp_client

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true, schema: { description: "A scenario of the plan. Not the baseline." }
  parameter :person_id, String, required: true
  parameter :from_unit_id, String, required: true, schema: { description: "The unit the place is in, or 'unassigned'." }
  parameter :from_position_id, String, schema: { description: "The position the place is in, when it is in one." }
  parameter :to_unit_id, String, allow_blank: false, schema: { description: "The unit to move to, or 'unassigned'. Give exactly one of this or to_position_id." }
  parameter :to_position_id, String, allow_blank: false, schema: { description: "A position of the scenario to place them in. Give exactly one of this or to_unit_id." }
  requires_any_of :to_unit_id, :to_position_id
  parameter :allocation, Numeric, schema: { exclusiveMinimum: 0, maximum: 1,
                                            description: "The new place's allocation. Required unless moving to 'unassigned'." }
  parameter :role, String, schema: { description: "The person's role in the new place, such as Lead." }

  # @return [Hash] `{ plan_id, scenario_id, person_id, placements }`
  def perform
    editor_scenario!
    ::TeamPlanning::Repository.new.holding_plan(plan_id!) do
      map = refusing_bad_plans { ::TeamPlanning::Resolution.new(context:, plan: plan!, scenario_id:).call }
      person = map.people.find { it.id == person_id } or raise Operations::Base::ParameterError, "This scenario has no such person"

      Operations::TeamPlanning::SetAssignment.call(
        context:, params: { plan_id: plan_id!, scenario_id:, person_id:, placements: placements(person, map), note: params[:note] }
      )
    end
  end

  private

  def editor_scenario!
    plan = Operations::TeamPlanning::Plan.call(context:, params: { plan_id: plan_id! })
    raise Operations::Base::ParameterError, "No such plan" unless plan[:role] == "editor"
    raise Operations::Base::ParameterError, "Today can't be edited. Fork a scenario and edit that." if scenario_id == plan[:plan_id]
  end

  def scenario_id = scenario_id!(:scenario_id)


  def person_id = uuid!(:person_id)

  # A place outside the plan's scope is kept as it is: the plan can't see it to move it.
  def placements(person, map)
    live = map.units.to_set(&:id)
    away = map.outside_places(person)
    held = ::TeamPlanning::Baseline::Membership.shares(person.memberships)
    moved, kept = held.partition { |place, _, _| !away.include?(place) && from?(place, live) }
    raise Operations::Base::ParameterError, "#{map.name_of(person_id)} holds no such place" if no_such_place?(moved, kept, live)
    raise Operations::Base::ParameterError, "This scenario has no such unit" unless to_position || to_unit == UNASSIGNED || live.include?(to_unit)
    raise Operations::Base::ParameterError, "This scenario has no such position" if to_position && map.positions.none? { it.id == to_position && live.include?(it.unit_id) }

    kept.reject! { |place, _, _| replaced?(place) }
    kept.map { |place, share, _| written(place, share) } + arriving
  end

  def replaced?(place)
    return place.position_id == to_position if to_position

    place.position_id.nil? && place.unit_id == to_unit
  end

  def from?(place, live)
    return !live.include?(place.unit_id) if from_unit == UNASSIGNED

    place.unit_id == from_unit && place.position_id == from_position
  end

  # Someone is in Unassigned only while they hold no place in a live unit.
  def no_such_place?(moved, kept, live)
    return kept.any? { |place, _, _| live.include?(place.unit_id) } if from_unit == UNASSIGNED

    moved.empty?
  end

  def from_position = params[:from_position_id].presence && uuid!(:from_position_id)

  def written(place, share)
    raise Operations::Base::ParameterError, "A place with no allocation has nothing left to share. Set its allocation first." unless share.positive?

    spot = place.position_id ? { position_id: place.position_id } : { unit_id: place.unit_id }
    { **spot, allocation: share.to_f, role: place.role }.compact
  end

  def arriving
    return [] if to_unit == UNASSIGNED
    raise Operations::Base::ParameterError, "allocation is required" if params[:allocation].nil?

    spot = to_position ? { position_id: to_position } : { unit_id: to_unit }
    [ { **spot, allocation: params[:allocation].to_f, role: params[:role].presence }.compact ]
  end

  def to_position
    return if params[:to_position_id].nil?
    raise Operations::Base::ParameterError, "Give to_unit_id or to_position_id, not both" unless params[:to_unit_id].nil?

    uuid!(:to_position_id)
  end

  def from_unit = unit_param(:from_unit_id)

  def to_unit = params[:to_unit_id].nil? ? nil : unit_param(:to_unit_id)

  def unit_param(name) = params[name] == UNASSIGNED ? UNASSIGNED : uuid!(name)
end
