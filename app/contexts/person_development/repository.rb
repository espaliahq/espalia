# frozen_string_literal: true

# Loads and stores PersonDevelopment aggregates via RailsEventStore.
#
# Uses EventStreamNaming to build tenant-namespaced stream names.
# Injects tenant_id into event metadata automatically.
#
class PersonDevelopment::Repository
  # @param event_store [RailsEventStore::JSONClient] defaults to global config
  def initialize(event_store: Rails.configuration.event_store)
    @event_store = event_store
    @repository = AggregateRoot::Repository.new(event_store)
  end

  # Loads the person development aggregate, yields it, and stores any new events.
  #
  # @param person_id [String] UUID of the person
  # @param framework_id [String] UUID of the framework
  # @yield [PersonDevelopment::Aggregate] the loaded aggregate
  def with_person_development(person_id, framework_id, &block)
    stream = EventStreamNaming.person_development_stream(person_id, framework_id)
    tenant = ActsAsTenant.current_tenant
    raise ArgumentError, "No tenant context available" unless tenant

    @event_store.with_metadata(tenant_id: tenant.id, person_id: person_id, framework_id: framework_id) do
      @repository.with_aggregate(PersonDevelopment::Aggregate.new, stream, &block)
    end
  end
end
