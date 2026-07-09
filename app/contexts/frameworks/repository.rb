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
  end

  # Loads the framework aggregate, yields it, stores any new events, and
  # writes a fresh {Frameworks::ExplorerGraph} snapshot — all inside one
  # ActiveRecord transaction so events and snapshot can never diverge.
  #
  # Automatically injects tenant_id into event metadata from the current
  # tenant context.
  #
  # @param framework_id [String] UUID of the framework
  # @yield [Frameworks::Aggregate] the loaded aggregate
  def with_framework(framework_id, &block)
    stream = EventStreamNaming.framework_stream(framework_id)
    tenant = ActsAsTenant.current_tenant
    raise ArgumentError, "No tenant context available" unless tenant

    snapshot_after = lambda do |aggregate|
      # Only rewrite the snapshot when this call actually mutated the
      # aggregate. Read-only uses (load-and-inspect) on an existing
      # framework would otherwise churn the graph row every request.
      events = aggregate.unpublished_events.to_a
      return if events.none?
      # ...and only when the mutation can affect what the graph renders.
      return if events.all? { |e| GRAPH_IRRELEVANT_EVENTS.include?(e.class) }

      graph = Frameworks::ExplorerGraphBuilder.new(aggregate).build
      Frameworks::ExplorerGraph.store(aggregate.framework_id, graph)
    end

    ActiveRecord::Base.transaction do
      @event_store.with_metadata(tenant_id: tenant.id) do
        @repository.with_aggregate(Frameworks::Aggregate.new, stream) do |aggregate|
          block.call(aggregate)
          # AggregateRoot::Repository#with_aggregate saves events on block
          # exit. We run the snapshot here so it sees the post-command state
          # *and* lands in the same outer AR transaction as the event write.
          snapshot_after.call(aggregate)
        end
      end
    end
  end
end
