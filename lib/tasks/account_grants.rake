# frozen_string_literal: true

namespace :account_grants do
  desc "Record the editor and planner grants the account flags hold that their events don't. Safe to re-run; predeploy runs it."
  task reconcile: :environment do
    failed = []
    Tenant.find_each do |tenant|
      # One correlation per tenant and run, so the feed shows a deploy's backfill as one change.
      report = AuditMetadata.with(acting_via: :system, correlation_id: SecureRandom.uuid) do
        AuditMetadata.wrap_event_store { AccountGrants::Reconciliation.new(tenant).call }
      end
      recorded = report.added + report.removed
      puts "[#{tenant.id}] #{recorded.zero? ? "nothing to record" : "recorded #{report.added} already held, #{report.removed} removed"}"
    rescue => e
      Rails.error.report(e, handled: true, context: { tenant_id: tenant.id })
      puts "[#{tenant.id}] failed: #{e.class}: #{e.message}"
      failed << tenant.id
    end
    # Every other tenant is recorded first, but the deploy must stop: the
    # rebuild that follows would clear a failed tenant's flags and replay nothing.
    abort "account_grants:reconcile failed for #{failed.size} tenant(s): #{failed.join(", ")}" if failed.any?
  end
end
