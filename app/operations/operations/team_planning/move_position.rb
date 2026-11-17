# frozen_string_literal: true

# Moves a position to another unit in a scenario, the way the scenario map's
# drag and "Move…" do [#285](https://github.com/espaliahq/espalia/issues/285).
# It writes only the unit through {EditPosition}, so the change is an
# ordinary PositionSet, the people in the position move with it, and every
# other field is kept. The checks and the write share the plan's lock.
#
# The baseline is Today and is refused here, whatever the caller.
class Operations::TeamPlanning::MovePosition < Operations::Base
  include Operations::TeamPlanning::PlanWrite

  description "Move a position to another unit in a scenario of a Team Planning plan, keeping its role, level, " \
              "FTE, basis, cost centre, hiring status and target start. The people in the position move with it. Written as one PositionSet. Refused on " \
              "the baseline, and unless the caller is one of the plan's editors."
  category :write
  approval :mcp_client

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true, schema: { description: "A scenario of the plan. Not the baseline." }
  parameter :position_id, String, required: true
  parameter :to_unit_id, String, required: true, schema: { description: "The unit the position moves to." }

  # @return [Hash] what {EditPosition} returns
  def perform
    editor_scenario!
    ::TeamPlanning::Repository.new.holding_plan(plan_id!) do
      map = Operations::TeamPlanning::ScenarioMap.call(context:, params: { plan_id: plan_id!, scenario_id: })
      position = map[:positions].find { it[:position_id] == uuid!(:position_id) } or
        raise Operations::Base::ParameterError, "This scenario has no such position"
      raise Operations::Base::ParameterError, "This position is in no unit and can't be moved" unless map[:units].any? { it[:id] == position[:unit_id] }
      raise Operations::Base::ParameterError, "This scenario has no such unit" unless map[:units].any? { it[:id] == uuid!(:to_unit_id) }
      raise Operations::Base::ParameterError, "The position is already in that unit" if position[:unit_id] == uuid!(:to_unit_id)

      Operations::TeamPlanning::EditPosition.call(context:, params: { plan_id: plan_id!, scenario_id:, position_id: position[:position_id],
                                                                      unit_id: uuid!(:to_unit_id) })
    end
  end

  private

  def editor_scenario!
    plan = Operations::TeamPlanning::Plan.call(context:, params: { plan_id: plan_id! })
    raise Operations::Base::ParameterError, "No such plan" unless plan[:role] == "editor"
    raise Operations::Base::ParameterError, "Today can't be edited. Fork a scenario and edit that." if scenario_id == plan[:plan_id]
  end

  def scenario_id = scenario_id!(:scenario_id)
end
