# frozen_string_literal: true

# The active tenant's settings for comparing a person with their level.
class Operations::Tenants::Comparisons < Operations::Base
  description "Read how people in the active tenant compare their capabilities with others on their role at a " \
              "level: whether it is on, the smallest group that shows, and how often the group scores are " \
              "taken. Refused unless the caller is a tenant admin."
  category :read
  approval :none

  # @param tenant [Tenant]
  # @return [Hash] the settings
  def self.payload(tenant)
    config = tenant.comparison_config
    { enabled: config.enabled, min_group_size: config.min_group_size,
      snapshot_every_months: config.snapshot_every_months }
  end

  # @raise [Pundit::NotAuthorizedError] unless the caller is a tenant admin
  def policy_check
    authorize ActsAsTenant.current_tenant, :update_comparisons?, policy_class: TenantPolicy
  end

  # @return [Hash] see {.payload}
  def perform = self.class.payload(ActsAsTenant.current_tenant)
end
