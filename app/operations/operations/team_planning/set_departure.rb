# frozen_string_literal: true

# Has someone leave in a scenario's step, as a DepartureSet change, with the
# position that backfills them [#256](https://github.com/espaliahq/espalia/issues/256).
# The step is the scenario's period: in it they stay on the map marked as
# leaving, and in the steps after it they are gone and the backfill stands
# alone. The link lives only on the departure, so withdrawing, clearing or
# undoing it drops the link. An optional leaving date within the step splits
# its cost between the leaver and the backfill. Every check runs under the
# plan's lock, after the editor check.
class Operations::TeamPlanning::SetDeparture < Operations::Base
  include Operations::TeamPlanning::ChangeWrite

  description "Have a person leave in a scenario of a Team Planning plan, optionally naming the position that " \
              "backfills them: it carries the budget and the headcount, and the leaver never counts as filling " \
              "it. In this scenario's step they stay on the map marked as leaving; in the steps after it they are " \
              "gone and the position stands alone. A leaving date within the step splits its cost: the leaver costs " \
              "up to that day and the backfill from the day after; without one, the backfill carries the whole step. " \
              "team_planning_withdraw_departure has them stay. Refused unless " \
              "the caller is one of the plan's editors."
  category :write
  approval :mcp_client

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true, schema: { description: "The scenario, or the plan's id for the baseline." }
  parameter :person_id, String, required: true
  parameter :position_id, String, schema: { description: "The backfill: a position the scenario has. Leave it out when the seat isn't backfilled." }
  parameter :leaves_on, String, schema: { format: "date", description: "Their last day, within the scenario's period. Leave it out to have them gone for the whole step." }

  # @return [Hash] `{ plan_id, scenario_id, person_id, position_id, leaves_on }`
  def perform
    person_id = uuid!(:person_id)
    position_id = params[:position_id].nil? ? nil : uuid!(:position_id)
    scenario_id = scenario_id!(:scenario_id)
    leaves_on = leaving_date
    end_state = { leaves_in_id: scenario_id, position_id:, leaves_on: }
    set_change!(::TeamPlanning::Events::DepartureSet, subject_id: person_id, end_state:) do |plan|
      raise Operations::Base::ParameterError, "No such person" unless ::Person.exists?(tenant_id: ActsAsTenant.current_tenant&.id, id: person_id)
      check_within_step!(plan, scenario_id, leaves_on) if leaves_on
      next if position_id.nil? || winning_change(plan, position_id, ::TeamPlanning::Events::PositionSet.facet)

      raise Operations::Base::ParameterError, "This scenario has no such position"
    end

    { plan_id: plan_id!, scenario_id:, person_id:, position_id:, leaves_on: leaves_on&.iso8601 }
  end

  private

  def leaving_date
    ::TeamPlanning::Events::DepartureSet.leaving_date(params[:leaves_on])
  rescue ::TeamPlanning::Error => e
    raise Operations::Base::ParameterError, e.message
  end

  def check_within_step!(plan, scenario_id, leaves_on)
    period = plan.period_of(scenario_id)
    raise Operations::Base::ParameterError, "The baseline has no period, so a departure in it takes no leaving date" unless period
    return if period.cover?(leaves_on)

    raise Operations::Base::ParameterError, "The leaving date must fall on or after the scenario's start, #{period.begin}" unless period.end
    raise Operations::Base::ParameterError, "The leaving date must fall within the scenario's period, #{period.begin} to #{period.end}"
  end
end
