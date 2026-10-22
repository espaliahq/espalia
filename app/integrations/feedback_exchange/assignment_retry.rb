# frozen_string_literal: true

# Cross-stream handler: when a person is assigned to a framework, any feedback
# a peer sent for them that was skipped for want of an assignment is imported
# without waiting for the next scheduled run.
#
# It only enqueues a sync, after the assignment commits, and only when the
# ledger holds such a record, so an HRIS sync assigning hundreds of people
# costs one indexed query each.
#
# NEVER register this as a projection: replaying it would re-run syncs.
class FeedbackExchange::AssignmentRetry
  # @return [Array<Class>]
  def self.handled_events
    [ PersonDevelopment::Events::PersonAssignedToFramework ]
  end

  # @param event [RubyEventStore::Event]
  def call(event)
    tenant = Tenant.find_by(id: event.metadata[:tenant_id])
    return if tenant.nil? || !tenant.feedback_exchange_config.configured?(tenant)

    waiting = ActsAsTenant.with_tenant(tenant) do
      FeedbackExchangeImport.retriable.where(recipient_id: event.data[:person_id], skip_reason: "no_assignment").exists?
    end
    return unless waiting

    ActiveRecord.after_all_transactions_commit { FeedbackExchange::SyncJob.perform_later(tenant) }
  end
end
