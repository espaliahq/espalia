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
#   bin/rails "events:projections:rebuild_if_stale[frameworks/published_state]"   # what predeploy runs
#   bin/rails events:projections:stamp_if_no_events                              # predeploy, before verify
#   bin/rails "events:projections:mark_rebuilt[frameworks/published_state]"
#   bin/rails "events:projections:mark_rebuilt[frameworks/published_state,4]"  # Path B promotion
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

      # Every projection's lock, as `rebuild` takes one, so a write that plans
      # from a projection's tables refuses while they are replayed.
      ProjectionVersion.with_operation_locks(classes.map { it::PROJECTION_NAME }) do
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
    end

    desc "Rebuild a projection from the event stream. Args: name, [tenant_id]"
    task :rebuild, %i[name tenant_id] => :environment do |_, args|
      name = args.fetch(:name) { abort "Usage: events:projections:rebuild[<name>,[<tenant_id>]]" }
      klass = Projections::Registry.fetch(name)

      single_tenant = args[:tenant_id].present?
      tenants = single_tenant ? [ Tenant.find(args[:tenant_id]) ] : Tenant.all.to_a
      abort "No tenants to rebuild." if tenants.empty?

      # One lock from first reset to final restamp: a promotion cannot slip
      # in between and be overwritten (see ProjectionVersion.with_operation_lock).
      ProjectionVersion.with_operation_lock(name) do
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
    end

    # What the predeploy hook runs for each REBUILD_ON_DEPLOY name. A rebuild
    # truncates the projection's live tables and replays them while the
    # previous release is still serving traffic, so every needless rebuild is
    # a minute or two of empty assessments in production. A variable left set
    # after its deploy (the runbook says to remove it; it was once forgotten
    # for four deploys) must therefore be inert once the stamp is current.
    desc "Rebuild a projection only if its stamped version is behind CODE_VERSION (predeploy)."
    task :rebuild_if_stale, [ :name ] => :environment do |_, args|
      name = args.fetch(:name) { abort "Usage: events:projections:rebuild_if_stale[<name>]" }
      klass = Projections::Registry.fetch(name)

      # Check and rebuild under the same lock, so the stamp read here is the
      # one the rebuild (or a concurrent promotion) actually acts on.
      ProjectionVersion.with_operation_lock(name) do
        applied = ProjectionVersion.find_by(name: name)&.version

        if applied == klass::CODE_VERSION
          puts "#{name} is already at CODE_VERSION #{applied} — skipping rebuild " \
               "(run events:projections:rebuild[#{name}] to force one)."
        elsif applied && applied > klass::CODE_VERSION
          # A promoted stamp on an image whose constant has not caught up yet
          # (Path B, or a rollback): rebuilding would restamp the LOWER version
          # and undo the promotion. Leave it; `verify` reports the mismatch.
          puts "#{name} is stamped at #{applied}, ahead of this image's CODE_VERSION #{klass::CODE_VERSION} — " \
               "skipping rebuild so the promotion is kept."
        else
          puts "#{name}: applied=#{applied || '(never rebuilt)'} code=#{klass::CODE_VERSION} — rebuilding."
          Rake::Task["events:projections:rebuild"].invoke(name)
        end
      end
    end

    # What predeploy runs before `verify`. A never-stamped projection whose
    # handled events do not exist yet has nothing to replay, so its rebuild is
    # a reset and a stamp; doing that here lets it ship without
    # REBUILD_ON_DEPLOY. A CODE_VERSION bump still needs an explicit rebuild.
    #
    # Stamps nothing while another projection is stale: verify would then fail
    # and leave the previous release serving, and any event of these types it
    # wrote would never reach a projection already stamped current.
    desc "Reset and stamp never-rebuilt projections that have no handled events yet (predeploy)."
    task stamp_if_no_events: :environment do
      event_store = Rails.configuration.event_store
      nothing_to_replay = ->(klass) { klass.handled_events.empty? || event_store.read.of_type(klass.handled_events).first.nil? }
      stamps = ProjectionVersion.pluck(:name, :version).to_h

      stale = Projections::Registry.classes.reject { |klass| stamps[klass::PROJECTION_NAME] == klass::CODE_VERSION }
      unstampable = stale.reject { |klass| stamps[klass::PROJECTION_NAME].nil? && nothing_to_replay.(klass) }
      if unstampable.any?
        puts "Not stamping new projections: #{unstampable.map { |k| k::PROJECTION_NAME }.join(', ')} " \
             "must be rebuilt first."
        next
      end

      stale.each do |klass|
        name = klass::PROJECTION_NAME

        ProjectionVersion.with_operation_lock(name) do
          next if ProjectionVersion.exists?(name: name) || !nothing_to_replay.(klass)

          Tenant.find_each { |tenant| klass.reset!(tenant: tenant) }
          ProjectionVersion.stamp!(klass)
          puts "#{name}: never rebuilt, no handled events to replay — reset and stamped at #{klass::CODE_VERSION}."
        end
      end
    end

    # The optional version is the runbook's Path B promotion: an out-of-band
    # rebuild on the shipped (unbumped) handler code already holds the state
    # the coming CODE_VERSION describes, so stamping that version up front
    # lets the bump deploy pass `verify` without a second rebuild.
    desc "Stamp a projection as rebuilt at its CODE_VERSION, or at an explicit version, without rebuilding (escape valve)."
    task :mark_rebuilt, %i[name version] => :environment do |_, args|
      name = args.fetch(:name) { abort "Usage: events:projections:mark_rebuilt[<name>,[<version>]]" }
      klass = Projections::Registry.fetch(name)
      version = args[:version].present? ? Integer(args[:version]) : klass::CODE_VERSION
      abort "Version must be a non-negative integer, got #{version}." if version.negative?

      # Forward-only and atomic: a concurrent lower promotion cannot win.
      row = ProjectionVersion.promote!(name, version)
      if row.version > version
        abort "Refusing to stamp #{name} at #{version}: already at #{row.version} (stamps only move forward)."
      end

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
