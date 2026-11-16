# frozen_string_literal: true

# Sets one rule ({TeamPlanning::RuleKind}) of any registered kind in a
# scenario, for the whole plan or for a unit and the units below it. Each rule
# story adds a kind, never a tool.
class Operations::TeamPlanning::SetRule < Operations::Base
  include Operations::TeamPlanning::ChangeWrite
  include Operations::TeamPlanning::PlanRead

  RULE = ::TeamPlanning::Events::RuleSet

  description "Set one rule in a scenario of a Team Planning plan, by its name from tenants_planning_rules, " \
              "for the whole plan or, with unit_id, for that unit and the units below it. value is an object " \
              "in the shape that rule's value_schema gives, and replaces the value above it whole. Steps after " \
              "the scenario, and its alternatives, inherit it unless they change it. To follow the parent " \
              "again, use team_planning_clear_change with facet 'rule:<name>'. A refusal names what is wrong, " \
              "never the value. Refused unless the caller is one of the plan's editors."
  category :write
  approval :mcp_client

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true, schema: { description: "The scenario, or the plan's id for the baseline." }
  parameter :unit_id, String, allow_blank: false, schema: { description: "Omit to set the rule for the whole plan." }
  parameter :rule, String, required: true, allow_blank: false
  parameter :value, Hash, required: true, schema: { type: "object", description: "In the rule's value_schema" }

  # @return [Hash] `{ plan_id, scenario_id, subject_id, rule, value }`, the value as the rule stored it
  def perform
    subject_id = params[:unit_id].nil? ? plan_id! : uuid!(:unit_id)
    refuse_unit_for_plan_wide_rule! unless params[:unit_id].nil?
    stored = nil
    set_change!(RULE, subject_id:, end_state: { rule: params[:rule], value: params[:value] }) do
      live_unit!(subject_id) unless params[:unit_id].nil?
      stored = RULE.end_state(rule: params[:rule], value: params[:value])
    end

    { plan_id: plan_id!, scenario_id: scenario_id!(:scenario_id), subject_id:, **stored }
  end

  private

  def refuse_unit_for_plan_wide_rule!
    kind = ::TeamPlanning::RuleKinds.all.find { it.rule_name == params[:rule] }
    raise Operations::Base::ParameterError, "#{params[:rule]} is set for the whole plan, not a unit" if kind&.plan_wide?
  end

  def live_unit!(unit_id)
    map = ::TeamPlanning::Resolution.new(context:, plan: plan!, scenario_id: scenario_id!(:scenario_id)).structure
    return if map.units.any? { it.id == unit_id }

    raise Operations::Base::ParameterError, "There is no such live unit in this scenario"
  end
end
