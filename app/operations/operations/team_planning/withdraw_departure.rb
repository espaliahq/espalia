# frozen_string_literal: true

# Has someone stay after all, as a DepartureWithdrawn change
# [#256](https://github.com/espaliahq/espalia/issues/256). It shares the
# departure's facet, so a later step or an alternative can overrule a
# departure it inherits, and the backfill link goes with it. A departure the
# scenario sets itself is cleared instead, so no override is left behind.
class Operations::TeamPlanning::WithdrawDeparture < Operations::Base
  include Operations::TeamPlanning::ChangeWrite

  description "Have a person stay in a scenario of a Team Planning plan when a scenario it follows has them " \
              "leave. Their backfill position stays, linked to nobody. Steps after the scenario, and its " \
              "alternatives, inherit this unless they set a departure again. Refused unless the caller is one " \
              "of the plan's editors."
  category :write
  approval :mcp_client

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true, schema: { description: "The scenario, or the plan's id for the baseline." }
  parameter :person_id, String, required: true

  # @return [Hash] `{ plan_id, scenario_id, person_id, withdrawn }`
  def perform
    person_id = uuid!(:person_id)
    set_change!(::TeamPlanning::Events::DepartureWithdrawn, subject_id: person_id) do |plan|
      departure = winning_change(plan, person_id, ::TeamPlanning::Events::DepartureSet.facet)
      raise Operations::Base::ParameterError, "This scenario has nobody leaving by that id" unless departure.is_a?(::TeamPlanning::Events::DepartureSet)
      next unless departure.data[:scenario_id] == scenario_id!(:scenario_id)

      raise Operations::Base::ParameterError, "This scenario sets that departure itself: clear it to follow its parent"
    end
    { plan_id: plan_id!, scenario_id: scenario_id!(:scenario_id), person_id:, withdrawn: true }
  end
end
