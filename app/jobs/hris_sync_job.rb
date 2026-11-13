# frozen_string_literal: true

# Background job that syncs employee data from a tenant's configured HRIS provider.
#
# Enqueued on a schedule (via HrisSyncAllTenantsJob) or triggered manually.
# Each execution is scoped to a single tenant. The job is idempotent.
#
# @example
#   HrisSyncJob.perform_later(tenant)
#
class HrisSyncJob < ApplicationJob
  # The Pass 5 result sets naming people the sync could not assign.
  SKIP_KEYS = %i[unmapped_titles missing_roles missing_levels missing_ordinals].freeze

  queue_as :default
  # Sync now pressed during a scheduled run would race it to record each new person.
  limits_concurrency to: 1, key: ->(tenant) { tenant.id }, duration: 1.hour

  retry_on Hris::Hibob::Errors::RateLimitError, wait: :polynomially_longer, attempts: 5
  retry_on Hris::Hibob::Errors::ApiError, wait: :polynomially_longer, attempts: 3

  discard_on Hris::Hibob::Errors::AuthenticationError do |job, error|
    Rails.logger.error("[HrisSyncJob] Auth failed for tenant #{job.arguments.first.id}: #{error.message}")
  end

  # @param tenant [Tenant] the tenant to sync
  def perform(tenant)
    return unless tenant.hris_config.configured?(tenant)

    adapter = Hris::BaseAdapter.for(tenant, correlation_id: job_id)
    result = adapter.sync_people

    Rails.logger.info(
      "[HrisSyncJob] Sync complete for tenant #{tenant.id}: " \
      "created=#{result[:created]} updated=#{result[:updated]} " \
      "deactivated=#{result[:deactivated]} org_graph_events=#{result[:org_graph_events]} " \
      "forgotten_skipped=#{result[:forgotten_skipped]} " \
      "errors=#{result[:errors].size}"
    )
    log_skipped_assignments(tenant, result)
  end

  private

  # The people Pass 5 could not place — previously computed and dropped, so a
  # renamed HRIS title left its holders on their old assignment unnoticed
  # (#436). The integrations page lists the same gaps.
  def log_skipped_assignments(tenant, result)
    skipped = SKIP_KEYS.filter_map do |key|
      values = Array(result[key])
      "#{key}=#{values.to_a.inspect}" if values.any?
    end
    return if skipped.empty?

    Rails.logger.warn("[HrisSyncJob] Assignments skipped for tenant #{tenant.id}: #{skipped.join(' ')}")
  end
end
