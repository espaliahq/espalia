# frozen_string_literal: true

# Enqueues a FeedbackExchange::SyncJob for every tenant whose exchange is set up.
# Scheduled every 15 minutes in config/recurring.yml.
class FeedbackExchange::SyncAllTenantsJob < ApplicationJob
  queue_as :default

  # @return [void]
  def perform
    Tenant.where("feedback_exchange_config->>'enabled' = ?", "true").find_each do |tenant|
      FeedbackExchange::SyncJob.perform_later(tenant) if tenant.feedback_exchange_config.configured?(tenant)
    end
  end
end
