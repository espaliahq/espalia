# frozen_string_literal: true

# One-off backfill of the first-class reporting manager onto every existing
# PersonDevelopment stream, from the current `Person.manager_id`.
#
# Idempotent — the aggregate no-ops when the recorded manager already matches,
# so re-running emits nothing. Run this BEFORE the Stage-2 hard guard so every
# active assessment stream carries its reporting manager. See the feature plan
# and docs/runbooks/projection-rebuild.md (take a snapshot first in production).
#
# Usage:
#   bin/rails events:backfill_reporting_managers
#   bin/rails "events:backfill_reporting_managers[<tenant_id>]"
namespace :events do
  desc "Backfill reporting managers onto PersonDevelopment streams from Person.manager_id"
  task :backfill_reporting_managers, [ :tenant_id ] => :environment do |_t, args|
    tenants = args[:tenant_id].present? ? Tenant.where(id: args[:tenant_id]) : Tenant.all
    handler = PersonDevelopment::CommandHandler.new
    total = 0

    tenants.find_each do |tenant|
      ActsAsTenant.with_tenant(tenant) do
        Rails.configuration.event_store.with_metadata(tenant_id: tenant.id) do
          PersonFrameworkAssignment.where(tenant_id: tenant.id).find_each do |assignment|
            manager_id = Person.where(id: assignment.person_id).pick(:manager_id)
            next if manager_id.nil?

            handler.record_reporting_manager(
              assignment.person_id, assignment.framework_id, manager_id, source: "backfill"
            )
            total += 1
          end
        end
      end
    end

    puts "Backfilled reporting managers across #{tenants.count} tenant(s); #{total} assignment(s) processed."
  end
end
