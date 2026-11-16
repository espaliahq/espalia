# frozen_string_literal: true

# One rule ({TeamPlanning::RuleKind}) of any registered kind, as a scenario
# resolves it for the whole plan or at a unit. Each rule story adds a kind,
# never a tool.
class Operations::TeamPlanning::Rule < Operations::Base
  include Operations::TeamPlanning::PlanRead

  description "Get one rule of a scenario of a Team Planning plan the caller is in, by its name from " \
              "tenants_planning_rules, as the scenario resolves it: for the whole plan or, with unit_id, at that " \
              "unit, where the unit and each unit above it beat the plan-wide value, which beats the tenant's " \
              "default, which beats the rule's own. A unit gone from the scenario takes its rules with it, so it " \
              "reads the plan-wide value; an id the scenario never held is refused. team_planning_overrides lists which scenario set it. " \
              "#{PRICED_AS_ARCHIVED} Refused, as an unknown plan, unless the caller is a member."
  category :read
  approval :none

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true, schema: { description: "The scenario, or the plan's id for the baseline." }
  parameter :unit_id, String, allow_blank: false, schema: { description: "Omit for the plan-wide value." }
  parameter :rule, String, required: true, allow_blank: false

  # @return [Hash] `{ plan_id, scenario_id, unit_id, rule, value }`, with `archived_on`, `priced_on` and `note` for an archived plan
  def perform
    plan = plan!
    scenario_id = scenario_id!(:scenario_id)
    unit_id = params[:unit_id].nil? ? nil : uuid!(:unit_id)
    kind = refusing_bad_plans { ::TeamPlanning::RuleKinds.fetch(params[:rule]) }
    rule = kind.rule_name
    map = refusing_bad_plans { ::TeamPlanning::Resolution.new(context:, plan:, scenario_id:).structure }

    live = unit_id && map.units.any? { it.id == unit_id }
    if unit_id && !live && map.retired_units.none? { it.id == unit_id }
      raise Operations::Base::ParameterError, "There is no such unit in this scenario"
    end

    { plan_id: plan.id, **priced_as_archived(plan), scenario_id:, unit_id:, rule:, value: kind.read(map.rule(rule, unit_id: live ? unit_id : nil)) }
  end
end
