# frozen_string_literal: true

# Enqueues individual HrisSyncJob for each tenant with HRIS sync enabled.
#
# Scheduled to run every 6 hours via config/recurring.yml.
#
class HrisSyncAllTenantsJob < ApplicationJob
  queue_as :default

  # @return [void]
  def perform
    Tenant.where("hris_config->>'sync_enabled' = ?", "true")
          .where("hris_config->>'provider' IS NOT NULL")
          .find_each do |tenant|
      HrisSyncJob.perform_later(tenant) if tenant.hris_config.configured?(tenant)
    end
  end
end
