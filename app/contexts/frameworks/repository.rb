# frozen_string_literal: true

# Loads and stores Framework aggregates via RailsEventStore.
#
# Uses EventStreamNaming to build tenant-namespaced stream names.
# Injects tenant_id into event metadata automatically.
#
class Frameworks::Repository
  # Events that never change anything the explorer graph renders — a commit
  # consisting solely of these skips the graph rebuild + JSONB row rewrite.
  # Discussion-thread traffic (chat cadence) would otherwise pay a full
  # aggregate-derived snapshot per one-line comment and serialize against
  # structural edits on the graph row.
  GRAPH_IRRELEVANT_EVENTS = [
    Frameworks::Events::SuggestionCommented,
    Frameworks::Events::SuggestionCommentEdited,
    Frameworks::Events::SuggestionCommentDeleted
  ].freeze

  # @param event_store [RailsEventStore::JSONClient] defaults to global config
  def initialize(event_store: Rails.configuration.event_store)
    @event_store = event_store
    @repository = AggregateRoot::Repository.new(event_store)
    @batch = nil
  end

  # Loads the framework aggregate, yields it, stores any new events, and
  # writes a fresh {Frameworks::ExplorerGraph} snapshot — all inside one
  # ActiveRecord transaction so events and snapshot can never diverge.
  #
  # Automatically injects tenant_id into event metadata from the current
  # tenant context.
  #
  # Inside a {#batch} for the same framework, yields the batch's in-memory
  # aggregate instead: no per-call replay, and event store + graph write are
  # deferred to the end of the batch.
  #
  # @param framework_id [String] UUID of the framework
  # @yield [Frameworks::Aggregate] the loaded aggregate
  def with_framework(framework_id, &block)
    return block.call(@batch[:aggregate]) if @batch && @batch[:framework_id] == framework_id

    stream = EventStreamNaming.framework_stream(framework_id)
    tenant = current_tenant!

    ActiveRecord::Base.transaction do
      @event_store.with_metadata(tenant_id: tenant.id) do
        @repository.with_aggregate(Frameworks::Aggregate.new, stream) do |aggregate|
          block.call(aggregate)
          # AggregateRoot::Repository#with_aggregate saves events on block
          # exit. We run the snapshot here so it sees the post-command state
          # *and* lands in the same outer AR transaction as the event write.
          snapshot_after(aggregate)
        end
      end
    end
  end

  # Unit-of-work for bulk writes (seeding, imports): loads the aggregate
  # ONCE, lets every {#with_framework} call inside the block reuse it, then
  # stores all accumulated events and writes the graph snapshot ONCE — all
  # in a single transaction. Without this, N commands cost N full-stream
  # replays and N graph rewrites (O(N²) total — 1,600 seed commands took
  # ~3 minutes; batched, one replay + one write).
  #
  # Synchronous projections fire at the single store, AFTER all events are
  # appended — code inside the block must not read projection-maintained
  # read models for state it created within the batch.
  #
  # @param framework_id [String] UUID of the framework
  # @yield block whose {#with_framework} calls join this unit of work
  def batch(framework_id, &block)
    raise ArgumentError, "batches cannot be nested" if @batch

    stream = EventStreamNaming.framework_stream(framework_id)
    tenant = current_tenant!

    ActiveRecord::Base.transaction do
      @event_store.with_metadata(tenant_id: tenant.id) do
        aggregate = @repository.load(Frameworks::Aggregate.new, stream)
        @batch = { framework_id: framework_id, aggregate: aggregate }
        begin
          block.call
        ensure
          @batch = nil
        end
        # Snapshot before store — store clears unpublished_events, which
        # snapshot_after's "did anything graph-relevant change" guard reads.
        snapshot_after(aggregate)
        @repository.store(aggregate, stream)
      end
    end
  end

  private

  # @return [Tenant] the current tenant context
  # @raise [ArgumentError] when no tenant context is set
  def current_tenant!
    ActsAsTenant.current_tenant || raise(ArgumentError, "No tenant context available")
  end

  # Rewrites the {Frameworks::ExplorerGraph} snapshot when the aggregate was
  # mutated in a way the graph renders. Read-only uses (load-and-inspect)
  # would otherwise churn the graph row every request.
  #
  # @param aggregate [Frameworks::Aggregate] the post-command aggregate
  def snapshot_after(aggregate)
    events = aggregate.unpublished_events.to_a
    return if events.none?
    # ...and only when the mutation can affect what the graph renders.
    return if events.all? { |e| GRAPH_IRRELEVANT_EVENTS.include?(e.class) }

    graph = Frameworks::ExplorerGraphBuilder.new(aggregate).build
    Frameworks::ExplorerGraph.store(aggregate.framework_id, graph)
  end
end
