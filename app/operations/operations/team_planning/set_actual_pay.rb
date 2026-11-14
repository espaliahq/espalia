# frozen_string_literal: true

# Holds a person's actual pay in a scenario, as a PlanDataSet change
# ([#317](https://github.com/espaliahq/espalia/issues/317)). The amount is
# base pay: cost adds the unit's on-cost on top. Its basis says whether FTE
# scales it, as many HR exports already pro-rate a part-timer's pay.
#
# The value seals under the person's key in the plan, so it reads unknown
# once they are forgotten. Only an editor with the see-pay right may write it.
# Approval stays `:mcp_client`: an `:in_app` approval stores its arguments in
# clear until someone confirms it, and these arguments are pay.
class Operations::TeamPlanning::SetActualPay < Operations::Base
  include Operations::TeamPlanning::ChangeWrite

  description "Hold a person's actual pay in a scenario of a Team Planning plan, so cost prices their seat from it " \
              "for members with the see-pay right; everyone else still sees band midpoints. The amount is base pay, " \
              "and cost adds the unit's on-cost on top. basis says what the amount is: full_time for a full-time " \
              "figure that the person's FTE scales, or actual for what they are paid as it is, already pro-rated, " \
              "which FTE leaves alone. period is year, month or hour; an hourly amount is a rate, made yearly " \
              "by the working_hours rule, so its basis is always full_time. The plan keeps it private to that person, so once they are forgotten it reads " \
              "as unknown and their seat goes unpriced. Clear it with team_planning_clear_change on facet data:pay. " \
              "Refused unless the caller is one of the plan's editors and holds the see-pay right."
  category :write
  approval :mcp_client

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true, schema: { description: "The scenario, or the plan's id for the baseline." }
  parameter :person_id, String, required: true
  parameter :amount, String, required: true, allow_blank: false, schema: { description: "Base pay for one period, such as \"92000\" or \"48.50\"." }
  parameter :currency, String, required: true, allow_blank: false, schema: { description: "An ISO 4217 code, such as AUD." }
  parameter :period, String, required: true, schema: { enum: PayBand::PERIODS }
  parameter :basis, String, required: true, schema: { enum: ::TeamPlanning::Events::PlanDataSet::PAY_BASES }

  # @return [Hash] `{ plan_id, scenario_id, person_id, pay: { amount, currency, period, basis } }`
  def perform
    person_id = uuid!(:person_id)
    value = params.slice(:amount, :currency, :period, :basis)
    set_change!(::TeamPlanning::Events::PlanDataSet, subject_id: person_id, end_state: { field: "pay", value: }) do
      raise Operations::Base::ParameterError, "No such person" unless ::Person.exists?(tenant_id: ActsAsTenant.current_tenant&.id, id: person_id)
    end

    { plan_id: plan_id!, scenario_id: scenario_id!(:scenario_id), person_id:, pay: ::TeamPlanning::Events::PlanDataSet.pay!(value) }
  end
end
