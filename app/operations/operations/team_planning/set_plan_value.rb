# frozen_string_literal: true

# Holds a value about a person in place of the Org Graph's, as a PlanDataSet
# change [#270](https://github.com/espaliahq/espalia/issues/270): a level the
# HRIS has wrong, or an FTE about to change. Each field is its own change, so
# correcting both keeps both. The value seals under the person's key in the
# plan and reads `{ removed: true }` once they are forgotten; capacity then
# counts their FTE as not known, never as the Org Graph's.
class Operations::TeamPlanning::SetPlanValue < Operations::Base
  include Operations::TeamPlanning::ChangeWrite

  # Pay has its own tool, which needs the see-pay right.
  FIELDS = (::TeamPlanning::Events::PlanDataSet::FIELDS.keys - %w[pay]).freeze

  description "Hold a person's level or FTE in a scenario of a Team Planning plan in place of the Org Graph's, " \
              "for a value the HRIS has wrong or that is about to change. An FTE is above 0 and at most 1. The " \
              "plan keeps the value private to that person, so once they are forgotten it reads as removed. Use " \
              "team_planning_set_planned_level for a promotion. Refused unless the caller is one of the plan's editors."
  category :write
  approval :mcp_client

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true, schema: { description: "The scenario, or the plan's id for the baseline." }
  parameter :person_id, String, required: true
  parameter :field, String, required: true, schema: { enum: FIELDS }
  parameter :value, String, required: true, allow_blank: false, schema: { description: "A level, or an FTE such as \"0.8\"." }

  # @return [Hash] `{ plan_id, scenario_id, person_id, field, value }`
  def perform
    person_id = uuid!(:person_id)
    field!
    end_state = { field: params[:field], value: params[:value] }
    set_change!(::TeamPlanning::Events::PlanDataSet, subject_id: person_id, end_state:) do
      raise Operations::Base::ParameterError, "No such person" unless ::Person.exists?(tenant_id: ActsAsTenant.current_tenant&.id, id: person_id)
    end

    { plan_id: plan_id!, scenario_id: scenario_id!(:scenario_id), person_id:, **::TeamPlanning::Events::PlanDataSet.end_state(end_state) }
  end

  private

  def field!
    field = params[:field].to_s
    return if FIELDS.include?(field)
    raise Operations::Base::ParameterError, "Pay has its own tool, team_planning_set_actual_pay" if field == "pay"

    raise Operations::Base::ParameterError, "A plan value is a person's #{FIELDS.to_sentence(two_words_connector: ' or ')}, not #{field.presence || 'nothing'}"
  end
end
