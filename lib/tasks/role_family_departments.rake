# frozen_string_literal: true

# One-off backfill that promotes the role-family `department` grouping from a
# read-model-only column to an event-sourced fact. For every role family that
# carries a department in the read model but not yet on its aggregate, emit a
# RoleFamilyUpdated{department:} so replays reproduce the grouping.
#
# Required BEFORE any PublishedState rebuild: with department now sourced from
# events, a rebuild that predates these events would drop the seeded grouping.
# The explorer-graph fallback to the read model covers only the pre-backfill
# window, not a premature rebuild — see Frameworks::ExplorerGraphBuilder.
#
# Idempotent — skips families whose aggregate already carries the value, so
# re-running emits nothing. Take a production snapshot first (see
# docs/runbooks/projection-rebuild.md).
#
# Usage:
#   bin/rails events:backfill_role_family_departments
#   bin/rails "events:backfill_role_family_departments[<tenant_id>]"
namespace :events do
  desc "Backfill event-sourced role-family department from the read model"
  task :backfill_role_family_departments, [ :tenant_id ] => :environment do |_t, args|
    tenants = args[:tenant_id].present? ? Tenant.where(id: args[:tenant_id]) : Tenant.all
    repository = Frameworks::Repository.new
    handler = Frameworks::CommandHandler.new
    total = 0

    tenants.find_each do |tenant|
      ActsAsTenant.with_tenant(tenant) do
        by_framework = FrameworkState::RoleFamily
          .where(tenant_id: tenant.id)
          .where.not(department: [ nil, "" ])
          .group_by(&:framework_id)

        by_framework.each do |framework_id, families|
          # Read each family's current event-sourced department once so re-runs
          # skip families already carrying the value (the aggregate has no
          # "unchanged" guard, so this is what keeps the task idempotent).
          aggregate_department = {}
          repository.with_framework(framework_id) do |aggregate|
            families.each do |rf|
              fam = aggregate.role_families[rf.role_family_id]
              aggregate_department[rf.role_family_id] = fam[:department] if fam
            end
          end

          families.each do |rf|
            next unless aggregate_department.key?(rf.role_family_id)
            next if aggregate_department[rf.role_family_id] == rf.department

            handler.update_role_family(framework_id, rf.role_family_id, department: rf.department)
            total += 1
          end
        end
      end
    end

    puts "Backfilled role-family departments across #{tenants.count} tenant(s); #{total} family(ies) updated."
  end
end
