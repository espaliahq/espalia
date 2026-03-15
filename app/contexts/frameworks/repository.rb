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

  # Loads the framework aggregate, yields it, and stores any new events.
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

    @event_store.with_metadata(tenant_id: tenant.id) do
      @repository.with_aggregate(Frameworks::Aggregate.new, stream, &block)
    end
  end
end
