# frozen_string_literal: true

# Closes an open position in a scenario.
class Operations::TeamPlanning::ClosePosition < Operations::Base
  include Operations::TeamPlanning::ChangeWrite

  description "Close an open position in a scenario of a Team Planning plan. Steps after the scenario, and its " \
              "alternatives, inherit the close unless they set the position again. team_planning_set_position " \
              "with the position_id reopens it. Refused unless the caller is one of the plan's editors."
  category :write
  approval :mcp_client

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true, schema: { description: "The scenario, or the plan's id for the baseline." }
  parameter :position_id, String, required: true

  # @return [Hash] `{ plan_id, scenario_id, position_id, closed }`
  def perform
    editable_plan!
    position_id = uuid!(:position_id)
    unless winning_change(position_id, ::TeamPlanning::Events::PositionSet.facet).is_a?(::TeamPlanning::Events::PositionSet)
      raise Operations::Base::ParameterError, "This scenario has no such open position"
    end

    set_change!(::TeamPlanning::Events::PositionClosed, subject_id: position_id)
    { plan_id: plan_id!, scenario_id: scenario_id!(:scenario_id), position_id:, closed: true }
  end
end
