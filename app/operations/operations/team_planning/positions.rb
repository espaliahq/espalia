# frozen_string_literal: true

# A scenario's open positions, resolved through {TeamPlanning::Resolution#call},
# with role and level names from the framework and a budget of committed
# (backfill) or planned (new). It shows no person, so the forgotten-person
# audit exempts it [#228](https://github.com/espaliahq/espalia/issues/228).
class Operations::TeamPlanning::Positions < Operations::Base
  include Operations::TeamPlanning::PlanRead

  description "List the open positions in a scenario of a Team Planning plan the caller is in: those its own " \
              "changes set, and those it inherits from the scenarios it follows. Each has its role and level " \
              "(with names from the framework; a name is null once the framework drops it), unit, FTE, basis and " \
              "budget: 'committed' for a backfill, 'planned' for a new position. Refused, as an unknown plan, " \
              "unless the caller is a member."
  category :read
  approval :none

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true, schema: { description: "The scenario, or the plan's id for the baseline." }

  # @return [Hash] `{ plan_id, scenario_id, positions }`
  def perform
    plan = plan!
    scenario_id = scenario_id!(:scenario_id)
    map = refusing_bad_plans { ::TeamPlanning::Resolution.new(context:, plan:, scenario_id:).call }
    positions = map.positions.map do |position|
      { position_id: position.id, **position.to_h.except(:id), budget: position.budget }
    end
    { plan_id: plan.id, scenario_id:, positions: }
  end
end
