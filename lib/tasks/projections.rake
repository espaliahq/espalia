# frozen_string_literal: true

# Projection rebuild orchestration.
#
# Run AFTER a deploy whose code change requires the projection's historical
# state to be recomputed (handler logic changed, new read model columns
# populated from past events, new projection added). See
# `docs/runbooks/projection-rebuild.md` before running in production.
#
# Usage:
#   bin/rails events:projections:list
#   bin/rails events:projections:verify
#   bin/rails "events:projections:rebuild[frameworks/published_state]"
#   bin/rails "events:projections:rebuild[frameworks/published_state,<tenant_id>]"
#   bin/rails "events:projections:mark_rebuilt[frameworks/published_state]"
#
# The registry lives in `lib/projections/registry.rb` so the rake task,
# tests, and predeploy guard share a single source of truth. Sync
# cross-stream handlers that DISPATCH commands are deliberately excluded —
# replaying them would re-fire side effects against already-applied state.
namespace :events do
  namespace :projections do
    desc "List replayable projections"
    task list: :environment do
      puts "Replayable projections:"
      Projections::Registry.names.each { |name| puts "  #{name}" }
    end

    desc "Verify every projection is at its current CODE_VERSION. Exit 1 on stale."
    task verify: :environment do
      stale = []
      Projections::Registry.names.each do |name|
        klass = Projections::Registry.fetch(name)
        applied = ProjectionVersion.find_by(name: name)&.version
        next if applied == klass::CODE_VERSION

        stale << { name: name, code: klass::CODE_VERSION, applied: applied || "(never rebuilt)" }
      end

      if stale.any?
        warn "Stale projections detected — refusing to deploy:"
        stale.each { |s| warn "  #{s[:name]}: code=#{s[:code]} applied=#{s[:applied]}" }
        warn ""
        warn "Resolve by running, against the new image:"
        warn "  bin/rails \"events:projections:rebuild[<name>]\""
        warn "Or for very large rebuilds, see docs/runbooks/projection-rebuild.md."
        exit 1
      end

      puts "OK — all #{Projections::Registry.names.size} projections at current CODE_VERSION"
    end

    desc "Rebuild every replayable projection across all tenants via single-pass global replay."
    task rebuild_all: :environment do
      tenants = Tenant.all.to_a
      abort "No tenants to rebuild." if tenants.empty?

      classes = Projections::Registry.classes
      puts "Rebuilding #{classes.size} projections via Projections::GlobalReplayer:"
      classes.each { |k| puts "  - #{k::PROJECTION_NAME}" }
      puts ""

      tenants.each do |tenant|
        puts "════ tenant #{tenant.id} ════"
        counts = Projections::GlobalReplayer.replay_all(tenant: tenant)
        total = counts.values.sum
        puts "[#{tenant.id}] global replay done — #{total} total handler invocations"
        counts.each { |klass, n| puts "  #{klass::PROJECTION_NAME}: #{n}" }
        puts ""
      end

      classes.each { |klass| ProjectionVersion.stamp!(klass) }
      puts "Stamped projection_versions for all #{classes.size} projections."
      puts "Run events:projections:verify to confirm."
    end

    desc "Rebuild a projection from the event stream. Args: name, [tenant_id]"
    task :rebuild, %i[name tenant_id] => :environment do |_, args|
      name = args.fetch(:name) { abort "Usage: events:projections:rebuild[<name>,[<tenant_id>]]" }
      klass = Projections::Registry.fetch(name)

      single_tenant = args[:tenant_id].present?
      tenants = single_tenant ? [ Tenant.find(args[:tenant_id]) ] : Tenant.all.to_a
      abort "No tenants to rebuild." if tenants.empty?

      total_applied = 0
      tenants.each do |tenant|
        ActsAsTenant.with_tenant(tenant) do
          puts "[#{tenant.id}] resetting #{name}…"
          klass.reset!(tenant: tenant)

          puts "[#{tenant.id}] replaying…"
          applied = Projections::Replayer.replay(projection_class: klass, tenant: tenant)
          total_applied += applied
          puts "[#{tenant.id}] done — #{applied} events"
        end
      end

      if single_tenant
        # Surgical rebuild — does NOT stamp the global version row.
        puts "Single-tenant rebuild complete (#{total_applied} events). projection_versions row unchanged."
      else
        ProjectionVersion.stamp!(klass)
        puts "All-tenants rebuild complete (#{total_applied} events). " \
             "projection_versions[#{name}] = #{klass::CODE_VERSION}."
      end
    end

    desc "Manually stamp a projection at its current CODE_VERSION without rebuilding (escape valve)."
    task :mark_rebuilt, [ :name ] => :environment do |_, args|
      name = args.fetch(:name) { abort "Usage: events:projections:mark_rebuilt[<name>]" }
      klass = Projections::Registry.fetch(name)
      row = ProjectionVersion.stamp!(klass)
      puts "Stamped #{name} as rebuilt at version #{row.version} (#{row.applied_at})."
      puts "NOTE: this is an escape valve — only use it when you have verifiably rebuilt the projection by other means."
    end

    desc "Run only the projection contract + rebuild round-trip tests (used by precommit)."
    task test_contracts: :environment do
      sh "bin/rails test test/lib/projections test/models/projection_version_test.rb " \
         "test/contexts/frameworks/projections " \
         "test/contexts/person_development/projections " \
         "test/contexts/assessment_cycles/projections"
    end
  end
end
