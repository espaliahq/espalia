# frozen_string_literal: true

# Has someone leave in a scenario's step, as a DepartureSet change, with the
# position that backfills them [#256](https://github.com/espaliahq/espalia/issues/256).
# The step is the scenario's period: in it they stay on the map marked as
# leaving, and in the steps after it they are gone and the backfill stands
# alone. The link lives only on the departure, so withdrawing, clearing or
# undoing it drops the link. Every check runs under the plan's lock, after
# the editor check.
class Operations::TeamPlanning::SetDeparture < Operations::Base
  include Operations::TeamPlanning::ChangeWrite

  description "Have a person leave in a scenario of a Team Planning plan, optionally naming the position that " \
              "backfills them: it carries the budget and the headcount, and the leaver never counts as filling " \
              "it. In this scenario's step they stay on the map marked as leaving; in the steps after it they are " \
              "gone and the position stands alone. team_planning_withdraw_departure has them stay. Refused unless " \
              "the caller is one of the plan's editors."
  category :write
  approval :mcp_client

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true, schema: { description: "The scenario, or the plan's id for the baseline." }
  parameter :person_id, String, required: true
  parameter :position_id, String, schema: { description: "The backfill: a position the scenario has. Leave it out when the seat isn't backfilled." }

  # @return [Hash] `{ plan_id, scenario_id, person_id, position_id }`
  def perform
    person_id = uuid!(:person_id)
    position_id = params[:position_id].nil? ? nil : uuid!(:position_id)
    end_state = { leaves_in_id: scenario_id!(:scenario_id), position_id: }
    set_change!(::TeamPlanning::Events::DepartureSet, subject_id: person_id, end_state:) do |plan|
      raise Operations::Base::ParameterError, "No such person" unless ::Person.exists?(tenant_id: ActsAsTenant.current_tenant&.id, id: person_id)
      next if position_id.nil? || winning_change(plan, position_id, ::TeamPlanning::Events::PositionSet.facet)

      raise Operations::Base::ParameterError, "This scenario has no such position"
    end

    { plan_id: plan_id!, scenario_id: scenario_id!(:scenario_id), person_id:, position_id: }
  end
end
