# frozen_string_literal: true

namespace :account_grants do
  desc "Record the editor and planner grants the account flags hold that their events don't. Safe to re-run; predeploy runs it."
  task reconcile: :environment do
    Tenant.find_each do |tenant|
      # One correlation per tenant and run, so the feed shows a deploy's backfill as one change.
      report = AuditMetadata.with(acting_via: :system, correlation_id: SecureRandom.uuid) do
        AuditMetadata.wrap_event_store { AccountGrants::Reconciliation.new(tenant).call }
      end
      recorded = report.added + report.removed
      puts "[#{tenant.id}] #{recorded.zero? ? "nothing to record" : "recorded #{report.added} already held, #{report.removed} removed"}"
      puts "[#{tenant.id}] skipped #{report.skipped_ids.size} flagged with no person: #{report.skipped_ids.join(", ")}" if report.skipped_ids.any?
    rescue => e
      # One tenant's stream must not block a deploy for every tenant. Its
      # flags still hold; the next run records them.
      Rails.error.report(e, handled: true, context: { tenant_id: tenant.id })
      puts "[#{tenant.id}] failed: #{e.class}: #{e.message}"
    end
  end
end
