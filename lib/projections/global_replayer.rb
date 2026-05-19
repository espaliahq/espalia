# frozen_string_literal: true

# Single-pass replay of every replayable projection for a tenant.
#
# Reads the event store once globally, dispatching each event to every
# registered projection that handles it. Cross-projection causality is
# preserved automatically by global event order — no per-projection
# rebuild dependency ordering required.
#
# Trade-offs vs. {Projections::Replayer}.replay:
#   * `Replayer.replay` is the right tool when only one projection's
#     handler logic has changed — scoped, faster (reads only that
#     projection's event types), keeps the other three projections'
#     stamps untouched.
#   * `GlobalReplayer.replay_all` is the right tool for full recovery —
#     event-store restored from backup, post-incident replay, a refactor
#     that touched every projection at once. One read pass beats N read
#     passes; truncate-everything-up-front means no shared-row ordering
#     concerns (the live event order does the work).
#
# Replay still does NOT publish events through the store — projections
# are called directly. Sync handlers that dispatch domain commands
# (excluded from `Projections::Registry`) remain quiescent.
module Projections::GlobalReplayer
  BATCH_SIZE = 1_000

  # Resets every registered projection for the tenant, then replays the
  # tenant's events in global insertion order through the projections
  # that handle each event type.
  #
  # @param tenant [Tenant]
  # @param event_store [RailsEventStore::Client]
  # @return [Hash{Class => Integer}] events applied per projection class
  def self.replay_all(tenant:, event_store: Rails.configuration.event_store)
    classes = Projections::Registry.classes
    dispatch_table = build_dispatch_table(classes)
    all_event_types = dispatch_table.keys
    return classes.index_with { 0 } if all_event_types.empty?

    counts = Hash.new(0)
    tenant_id_str = tenant.id.to_s

    Projections::Replayer.with_replay_mode do
      ActsAsTenant.with_tenant(tenant) do
        # Truncate every projection's read models first. Order doesn't
        # matter — no projection's `reset!` cascades into another
        # projection's owned tables. The dispatch loop below recreates
        # rows in live event order, which is the correct order by
        # construction.
        classes.each { |klass| klass.reset!(tenant: tenant) }

        event_store.read.of_type(all_event_types).in_batches(BATCH_SIZE).each do |event|
          next unless event.metadata[:tenant_id].to_s == tenant_id_str

          dispatch_table[event.class].each do |projection|
            projection.call(event)
            counts[projection.class] += 1
          end
        end
      end
    end

    counts
  end

  # Builds `{ EventClass => [projection_instance, …] }`. One instance
  # per projection class, shared across all of that class's handled
  # event types — so a single replay carries the projection's
  # accumulator state (if any) across events, matching live behaviour.
  def self.build_dispatch_table(classes)
    classes.each_with_object({}) do |klass, table|
      instance = klass.new
      klass.handled_events.each do |event_class|
        (table[event_class] ||= []) << instance
      end
    end
  end
  private_class_method :build_dispatch_table
end
