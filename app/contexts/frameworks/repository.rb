# frozen_string_literal: true

# Loads and stores Framework aggregates via RailsEventStore.
#
# Uses EventStreamNaming to build tenant-namespaced stream names.
# Injects tenant_id into event metadata automatically.
#
class Frameworks::Repository
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
      # Skip the snapshot when no command ran (e.g. a read-only use of the
      # repository on a framework that hasn't been created yet). The
      # aggregate's framework_id is only populated once FrameworkCreated
      # has been applied.
      return unless aggregate.framework_id

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
