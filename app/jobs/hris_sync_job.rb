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
  queue_as :default

  retry_on Hris::Hibob::Errors::RateLimitError, wait: :polynomially_longer, attempts: 5
  retry_on Hris::Hibob::Errors::ApiError, wait: :polynomially_longer, attempts: 3

  discard_on Hris::Hibob::Errors::AuthenticationError do |job, error|
    Rails.logger.error("[HrisSyncJob] Auth failed for tenant #{job.arguments.first.id}: #{error.message}")
  end

  # @param tenant [Tenant] the tenant to sync
  def perform(tenant)
    return unless tenant.hris_config.configured?(tenant)

    adapter = resolve_adapter(tenant)
    result = adapter.sync_people

    Rails.logger.info(
      "[HrisSyncJob] Sync complete for tenant #{tenant.id}: " \
      "created=#{result[:created]} updated=#{result[:updated]} " \
      "deactivated=#{result[:deactivated]} errors=#{result[:errors].size}"
    )
  end

  private

  # Resolves the correct adapter based on the tenant's HRIS provider.
  #
  # @param tenant [Tenant]
  # @return [Integrations::Hris::BaseAdapter]
  def resolve_adapter(tenant)
    case tenant.hris_config.provider
    when "hibob"
      Hris::Hibob::Adapter.new(tenant)
    else
      raise "Unknown HRIS provider: #{tenant.hris_config.provider}"
    end
  end
end
