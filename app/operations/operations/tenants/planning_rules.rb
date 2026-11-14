# frozen_string_literal: true

# The Team Planning rules a plan may set, each with the default every plan
# starts from.
class Operations::Tenants::PlanningRules < Operations::Base
  include Operations::Tenants::PlanningRuleSupport

  description "List the Team Planning rules a plan may set. Each gives its description, value_schema (the " \
              "shape of its value), built_in_default, and the active tenant's own tenant_default with who " \
              "set it and when, or null where the tenant hasn't set one. A plan follows the tenant default, " \
              "else the built-in one, until it sets the rule itself. Refused unless the caller is a tenant admin."
  category :read
  approval :none

  # @return [Hash] `{ planning_rules: [...] }`, by rule
  def perform
    kinds = TeamPlanning::RuleKinds.all.sort_by(&:rule_name)
    records = PlanningRuleDefault.where(rule: kinds.map(&:rule_name)).index_by(&:rule)
    names = editor_names(records.values)
    { planning_rules: kinds.map { rule_payload(it, records[it.rule_name], names) } }
  end
end
