# frozen_string_literal: true

# Sets how people compare their assessment with others on their role at a
# level: whether they can, the smallest group that shows, and how often the
# group scores are taken. Only the settings given change.
class Operations::Tenants::UpdateComparisons < Operations::Base
  description "Set how people in the active tenant compare their capabilities with others on their role at a " \
              "level: enabled turns the comparison on or off; min_group_size is the fewest people a level " \
              "needs before its scores show (at least 4, default 5) on the comparison, and in the capability " \
              "attainment report to a viewer who can't open every assessment in the group (today every viewer of " \
              "that report can; a closed cycle's report keeps at least the size in force when it closed); snapshot_every_months is how often the group scores are taken, on the 1st " \
              "of the month (1, 3 or 6, default 1). Only the settings given change. Refused unless the caller " \
              "is a tenant admin."
  category :write
  approval :in_app

  parameter :enabled, :boolean
  parameter :min_group_size, Integer, schema: {
    type: "integer", minimum: ComparisonConfig::LOWEST_MIN_GROUP_SIZE, maximum: ComparisonConfig::HIGHEST_MIN_GROUP_SIZE
  }
  parameter :snapshot_every_months, Integer, allowed: ComparisonConfig::SNAPSHOT_INTERVALS
  requires_any_of :enabled, :min_group_size, :snapshot_every_months

  # @raise [Pundit::NotAuthorizedError] unless the caller is a tenant admin
  def policy_check
    authorize ActsAsTenant.current_tenant, :update_comparisons?, policy_class: TenantPolicy
  end

  # Turning comparisons on takes a snapshot only when one is due, as the hourly
  # job would: the first, or one the interval says is overdue. At most one a
  # month, so switching off and on again is no way to take one on demand.
  #
  # @return [Hash] the settings as they now stand
  # @raise [ParameterError] when a setting is out of range
  def perform
    tenant = ActsAsTenant.current_tenant
    turned_on = false
    tenant.with_lock do
      config = tenant.comparison_config.dup
      was_on = config.enabled
      config.assign_attributes(params.slice(:enabled, :min_group_size, :snapshot_every_months).compact)
      raise ParameterError, config.errors.full_messages.to_sentence unless config.valid?

      tenant.update!(comparison_config: config)
      turned_on = config.enabled && !was_on
    end
    LevelComparisons::TakeDueSnapshotsJob.perform_later(tenant) if turned_on
    Operations::Tenants::Comparisons.payload(tenant)
  end
end
