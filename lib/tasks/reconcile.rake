# frozen_string_literal: true

namespace :events do
  desc "Record what each listed table holds that its tenant stream doesn't, then adopt the projections they write. Safe to re-run; predeploy runs it."
  task reconcile: :environment do
    failed = []
    Tenant.find_each do |tenant|
      # One correlation per tenant and run, so the feed shows a deploy's backfill as one change.
      AuditMetadata.with(acting_via: :system, correlation_id: SecureRandom.uuid) do
        Projections::Reconcilers.names.each do |name|
          report = AuditMetadata.wrap_event_store { Projections::Reconcilers.fetch(name).new(tenant).call }
          summary = "recorded #{report.added} already held, #{report.removed} removed, #{report.changed} changed"
          puts "#{name} [#{tenant.id}] #{report.recorded.zero? ? "nothing to record" : summary}"
        rescue => e
          Rails.error.report(e, handled: true, context: { tenant_id: tenant.id, reconciler: name })
          puts "#{name} [#{tenant.id}] failed: #{e.class}: #{e.message}"
          failed << "#{name} [#{tenant.id}]"
        end
      end
    end
    # Every other tenant is recorded first, but the deploy must stop: the
    # rebuild that follows would set a failed tenant's table from a stream
    # that lacks what the table holds. Nothing is adopted either.
    abort "events:reconcile failed for #{failed.size}: #{failed.join(", ")}" if failed.any?

    Projections::Reconcilers.adopt.each { puts "#{it}: adopted, stamped at its CODE_VERSION without a reset." }
  end
end
