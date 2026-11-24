# frozen_string_literal: true

# What the rule default tools share: the admin-only check and the payload
# each returns. A refusal never repeats a value, so a rule can't reach a log
# through an error message
# [#225](https://github.com/espaliahq/espalia/issues/225).
#
# Admins only, so a planner or an Org Graph editor is refused. The tools live
# under Tenants, beside pay bands, because a default is a tenant setting that
# sits outside any plan.
module Operations::Tenants::PlanningRuleSupport
  include Operations::Tenants::EditorNames
  include Operations::Tenants::PlanningInputWrites

  # @raise [Pundit::NotAuthorizedError] unless the caller is a tenant admin
  def policy_check
    authorize ActsAsTenant.current_tenant, :manage_planning_rules?, policy_class: TenantPolicy
  end

  private

  # @param kind [Class<TeamPlanning::RuleKind>]
  # @param record [PlanningRuleDefault, nil] the tenant's default, if it set one
  # @param names [Hash{String => String}] from {#editor_names}
  # @return [Hash]
  def rule_payload(kind, record, names)
    {
      rule: kind.rule_name,
      description: kind.description,
      value_schema: kind.json_schema,
      built_in_default: kind.default.deep_stringify_keys,
      tenant_default: record&.value,
      updated_at: record&.updated_at&.iso8601,
      updated_by: record && names[editor_id(record)]
    }
  end
end
