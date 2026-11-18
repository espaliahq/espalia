# frozen_string_literal: true

# The active tenant's settings for comparing a person with their level.
class Operations::Tenants::Comparisons < Operations::Base
  description "Read how people in the active tenant compare their capabilities with others on their role at a " \
              "level: whether it is on, the smallest group that shows, how often the group scores are taken, " \
              "when the snapshot comparisons show was taken and when the next is due. Refused unless the " \
              "caller is a tenant admin."
  category :read
  approval :none

  # @param tenant [Tenant]
  # @return [Hash] the settings, the day the snapshot comparisons show was
  #   taken (nil before the first) and the day the next is due
  def self.payload(tenant)
    config = tenant.comparison_config
    last = ActsAsTenant.with_tenant(tenant) { LevelComparisonSnapshot.latest&.taken_on }
    { enabled: config.enabled, min_group_size: config.min_group_size,
      snapshot_every_months: config.snapshot_every_months, last_snapshot_on: last&.iso8601,
      next_snapshot_on: (config.next_snapshot_on(last, today: tenant.today).iso8601 if config.enabled) }
  end

  # @raise [Pundit::NotAuthorizedError] unless the caller is a tenant admin
  def policy_check
    authorize ActsAsTenant.current_tenant, :update_comparisons?, policy_class: TenantPolicy
  end

  # @return [Hash] see {.payload}
  def perform = self.class.payload(ActsAsTenant.current_tenant)
end
