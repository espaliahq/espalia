# frozen_string_literal: true

# Hourly (config/recurring.yml): takes a level comparison snapshot for every
# tenant with comparisons on whose next one is due by its own today, so the
# 1st of the month arrives in each tenant's time zone. A missed run catches
# up on the next.
class LevelComparisons::TakeDueSnapshotsJob < ApplicationJob
  queue_as :default
  limits_concurrency to: 1, key: "level_comparisons_take_due_snapshots", duration: 1.hour

  # @param tenant [Tenant, nil] just this tenant, as when comparisons are turned on; every tenant when nil
  # @return [void]
  def perform(tenant = nil)
    tenant ? take_if_due(tenant) : Tenant.find_each { |t| take_if_due(t) }
  end

  private

  # One tenant's failure must not stop the others; it stays due for the next run.
  def take_if_due(tenant)
    config = tenant.comparison_config
    return unless config.enabled

    today = tenant.today
    last = ActsAsTenant.with_tenant(tenant) { LevelComparisonSnapshot.latest&.taken_on }
    return if config.next_snapshot_on(last, today:) > today

    LevelComparisonSnapshot.take!(tenant:, on: today)
  rescue => e
    Rails.error.report(e, context: { tenant_id: tenant.id, job: self.class.name })
  end
end
