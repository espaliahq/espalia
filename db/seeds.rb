# frozen_string_literal: true

# Force line-buffered stdout so seed progress shows up live under Render's
# log collector (Ruby's default block-buffers stdout when it isn't a TTY,
# which hides multi-minute seed runs until the process exits).
$stdout.sync = true

# Idempotent in every environment: run it again and it converges.
#
# Production seeds no demo content — the admin, and optionally one empty
# workspace (SEED_TENANT_SLUG + SEED_TENANT_NAME) with a starter framework
# (SEED_FRAMEWORK_FILE, shaped like db/seeds/null_island_framework.yml).
# Everything else — people, cycles, ratings — a real instance imports or
# creates through the app (see docs/import-your-framework.md).
#
# Development and test get the Null Island Systems demo tenant (ExampleSeed):
# the example framework, ten people, an open cycle, ratings, evidence,
# pending suggestions and an open draft.

# See SeedAdmin for the contract: dev default, SEED_ADMIN_* override,
# no-op once an admin exists, and a clear error on a first production
# deploy that sets neither.
admin_user = SeedAdmin.bootstrap!

if Rails.env.production?
  slug = ENV["SEED_TENANT_SLUG"].presence
  name = ENV["SEED_TENANT_NAME"].presence
  if slug && name
    tenant = Tenant.find_or_create_by!(slug: slug) { |t| t.name = name }
    ActsAsTenant.with_tenant(tenant) do
      TenantUser.find_or_create_by!(tenant: tenant, user: admin_user) { |tu| tu.role = :admin }
    end
    puts "Workspace ready: #{name} (#{slug})"
    if ENV["SEED_FRAMEWORK_FILE"].present?
      ActsAsTenant.with_tenant(tenant) { Rake::Task["frameworks:seed"].execute }
    end
  else
    puts "No workspace seeded. Set SEED_TENANT_SLUG and SEED_TENANT_NAME to bootstrap one, " \
         "with SEED_FRAMEWORK_FILE for a starter framework."
  end
else
  require_relative "../lib/tasks/example_seed"
  ExampleSeed.new(admin_user: admin_user).call
end
