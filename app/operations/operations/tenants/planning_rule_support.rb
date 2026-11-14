# frozen_string_literal: true

# What the rule default tools share: the admin-only check and the payload
# each returns.
module Operations::Tenants::PlanningRuleSupport
  include Operations::Tenants::EditorNames

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
      updated_by: record && names[record.updated_by_id]
    }
  end
end
