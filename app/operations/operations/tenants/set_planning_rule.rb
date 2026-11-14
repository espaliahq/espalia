# frozen_string_literal: true

# Sets the active tenant's default for one Team Planning rule.
#
# Approval is :in_app, as for the tenant's other settings.
class Operations::Tenants::SetPlanningRule < Operations::Base
  include Operations::Tenants::PlanningRuleSupport

  description "Set the active tenant's default for one Team Planning rule, by its name from " \
              "tenants_planning_rules. value is an object in the shape that rule's value_schema gives. Every " \
              "plan follows it until the plan sets the rule itself. A refusal names what is wrong, never the " \
              "value. Returns the rule as tenants_planning_rules lists it. Refused unless the caller is a tenant admin."
  category :write
  approval :in_app

  parameter :rule, String, required: true, allow_blank: false
  parameter :value, Hash, required: true, schema: { type: "object", description: "In the rule's value_schema" }

  # @return [Hash] the rule, as tenants_planning_rules lists it
  # @raise [ParameterError] for an unknown rule, or a value the rule refuses
  def perform
    kind = TeamPlanning::RuleKinds.fetch(params[:rule])
    value = TeamPlanning::RuleKinds.check(params[:rule], params[:value])
    record = ActsAsTenant.current_tenant.with_lock do
      PlanningRuleDefault.find_or_initialize_by(rule: kind.rule_name).tap { it.update!(value:, updated_by: context.user) }
    end
    rule_payload(kind, record, editor_names([ record ]))
  rescue TeamPlanning::Error => e
    raise ParameterError, e.message
  end
end
