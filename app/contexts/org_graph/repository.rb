# frozen_string_literal: true

# Loads and stores Org Graph aggregates via RailsEventStore.
#
# Uses EventStreamNaming to build tenant-namespaced stream names.
# Injects tenant_id into event metadata automatically.
#
class OrgGraph::Repository
  # @param event_store [RailsEventStore::JSONClient] defaults to global config
  def initialize(event_store: Rails.configuration.event_store)
    @event_store = event_store
    @repository = AggregateRoot::Repository.new(event_store)
  end

  # Loads a person's aggregate, yields it, and stores any new events.
  #
  # @param person_id [String] UUID of the person
  # @yield [OrgGraph::PersonAggregate] the loaded aggregate
  # @raise [ArgumentError] if no tenant context is available
  def with_person(person_id, &block)
    with_tenant_metadata do
      @repository.with_aggregate(OrgGraph::PersonAggregate.new, EventStreamNaming.person_stream(person_id), &block)
    end
  end

  private

  def with_tenant_metadata(&block)
    tenant = ActsAsTenant.current_tenant
    raise ArgumentError, "No tenant context available" unless tenant

    @event_store.with_metadata(tenant_id: tenant.id, &block)
  end
end
