# frozen_string_literal: true

# Loads and stores Framework aggregates via RailsEventStore.
#
# Uses EventStreamNaming to build tenant-namespaced stream names.
# Injects tenant_id into event metadata automatically.
#
class Frameworks::Repository
  # Raised at the end of a {#batch} when a command inside it failed AFTER
  # applying events and the failure was rescued by the batch block. Committing
  # would persist the failed command's partial events — event history is
  # immutable, so the whole batch refuses to commit instead.
  BatchAbortedError = Class.new(StandardError)

  # Events that never change anything the explorer graph renders — a commit
  # consisting solely of these skips the graph rebuild + JSONB row rewrite.
  # Discussion-thread traffic (chat cadence) would otherwise pay a full
  # aggregate-derived snapshot per one-line comment and serialize against
  # structural edits on the graph row.
  GRAPH_IRRELEVANT_EVENTS = [
    Frameworks::Events::SuggestionCommented,
    Frameworks::Events::SuggestionCommentEdited,
    Frameworks::Events::SuggestionCommentDeleted,
    # Clarifications propose no content — the graph carries none of their state.
    Frameworks::Events::ClarificationRequested,
    Frameworks::Events::ClarificationResolved,
    # Migration mappings live in their own read model; the graph never reads them.
    Frameworks::Events::MigrationMappingDefined
  ].freeze

  # The active batch is execution-state-local (per thread/fiber), NOT
  # per-repository-instance: the house pattern builds a fresh
  # `Frameworks::Repository` per handler/Operation, so instance state would
  # let a second handler inside the batch block silently bypass the batch —
  # loading a stream that is missing the batch's unstored events and then
  # colliding with its expected-version at the final store.
  #
  # @return [Hash, nil] the active batch state for this execution context
  def self.current_batch
    ActiveSupport::IsolatedExecutionState[:frameworks_repository_batch]
  end

  # @param state [Hash, nil]
  def self.current_batch=(state)
    ActiveSupport::IsolatedExecutionState[:frameworks_repository_batch] = state
  end

  # @param event_store [RailsEventStore::JSONClient] defaults to global config
  def initialize(event_store: Rails.configuration.event_store)
    @event_store = event_store
    @repository = AggregateRoot::Repository.new(event_store)
  end

  # Loads the framework aggregate, yields it, stores any new events, and
  # writes a fresh {Frameworks::ExplorerGraph} snapshot — all inside one
  # ActiveRecord transaction so events and snapshot can never diverge.
  #
  # Automatically injects tenant_id into event metadata from the current
  # tenant context.
  #
  # Inside a {#batch} for the same framework — from ANY repository instance
  # on the same thread — yields the batch's in-memory aggregate instead: no
  # per-call replay, and event store + graph write are deferred to the end
  # of the batch. A call for a different framework inside a batch raises
  # (its transaction would silently join the batch's and be rolled back
  # with it).
  #
  # @param framework_id [String] UUID of the framework
  # @yield [Frameworks::Aggregate] the loaded aggregate
  # @return [Object] the block's return value
  def with_framework(framework_id, &block)
    if (batch = self.class.current_batch)
      return call_in_batch(batch, framework_id, &block)
    end

    stream = EventStreamNaming.framework_stream(framework_id)
    tenant = current_tenant!
    result = nil

    ActiveRecord::Base.transaction do
      @event_store.with_metadata(tenant_id: tenant.id) do
        @repository.with_aggregate(Frameworks::Aggregate.new, stream) do |aggregate|
          result = block.call(aggregate)
          # AggregateRoot::Repository#with_aggregate saves events on block
          # exit. We run the snapshot here so it sees the post-command state
          # *and* lands in the same outer AR transaction as the event write.
          snapshot_after(aggregate)
        end
      end
    end
    result
  end

  # Unit-of-work for bulk writes (seeding, imports): loads the aggregate
  # ONCE, lets every {#with_framework} call inside the block — from any
  # handler/repository instance on this thread — reuse it, then stores all
  # accumulated events and writes the graph snapshot ONCE, all in a single
  # transaction. Without this, N commands cost N full-stream replays and N
  # graph rewrites (O(N²) total — 1,600 seed commands took ~3 minutes;
  # batched, one replay + one write).
  #
  # Synchronous projections fire at the single store, AFTER all events are
  # appended — code inside the block must not read projection-maintained
  # read models for state it created within the batch.
  #
  # A command that raises after applying events poisons the batch: even if
  # the block rescues and continues, the batch raises {BatchAbortedError}
  # instead of committing the partial command (see {#call_in_batch}).
  #
  # @param framework_id [String] UUID of the framework
  # @yield block whose {#with_framework} calls join this unit of work
  # @return [Object] the block's return value
  def batch(framework_id, &block)
    raise ArgumentError, "batches cannot be nested" if self.class.current_batch

    with_framework(framework_id) do |aggregate|
      state = {
        framework_id: framework_id,
        aggregate: aggregate,
        tenant_id: current_tenant!.id,
        poisoned: false
      }
      self.class.current_batch = state
      result =
        begin
          block.call
        ensure
          self.class.current_batch = nil
        end
      if state[:poisoned]
        raise BatchAbortedError,
              "a command inside the batch failed after applying events; " \
              "committing would persist a partial command, so the batch was aborted"
      end
      result
    end
  end

  private

  # Runs one {#with_framework} call against the active batch's in-memory
  # aggregate. Guards the assumptions the deferred store relies on:
  # same framework, same tenant, and no partially-applied command surviving
  # a rescued failure (single-command dispatch discards a failed command's
  # events; a batch must never silently commit them).
  def call_in_batch(batch, framework_id, &block)
    unless batch[:framework_id] == framework_id
      raise ArgumentError,
            "cannot use framework #{framework_id} inside a batch for " \
            "#{batch[:framework_id]} — its writes would silently join (and " \
            "roll back with) the batch transaction"
    end
    unless current_tenant!.id == batch[:tenant_id]
      raise ArgumentError, "tenant context changed inside the batch"
    end

    aggregate = batch[:aggregate]
    events_before = aggregate.unpublished_events.count
    begin
      block.call(aggregate)
    rescue StandardError
      batch[:poisoned] = true if aggregate.unpublished_events.count > events_before
      raise
    end
  end

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
