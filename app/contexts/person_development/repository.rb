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

  # The writes a forgotten person's stream still takes. Each call that skips
  # the refusal names one; an append from it races the erase unlocked, so
  # its events must carry nothing about the person that the erase removes.
  FORGOTTEN_ALLOWED = %i[framework_migration cycle_ending].freeze

  # Loads the person development aggregate, yields it, and stores any new events.
  #
  # @param person_id [String] UUID of the person
  # @param framework_id [String] UUID of the framework
  # @param forgotten [Symbol, nil] the reason from {FORGOTTEN_ALLOWED} this
  #   write goes ahead for a forgotten person; nil refuses them
  # @yield [PersonDevelopment::Aggregate] the loaded aggregate
  # @raise [PersonDevelopment::ForgottenSubject::Forgotten] when the person has been forgotten
  def with_person_development(person_id, framework_id, forgotten: nil, &block)
    raise ArgumentError, "unknown forgotten-person exception #{forgotten.inspect}" if forgotten && !FORGOTTEN_ALLOWED.include?(forgotten)

    stream = EventStreamNaming.person_development_stream(person_id, framework_id)
    tenant = ActsAsTenant.current_tenant
    raise ArgumentError, "No tenant context available" unless tenant

    Person.transaction do
      PersonDevelopment::ForgottenSubject.refuse!(person_id) unless forgotten
      @event_store.with_metadata(tenant_id: tenant.id, person_id: person_id, framework_id: framework_id) do
        @repository.with_aggregate(PersonDevelopment::Aggregate.new, stream, &block)
      end
    end
  end

  # @param person_id [String] UUID of the person
  # @param framework_id [String] UUID of the framework
  # @return [PersonDevelopment::Aggregate] the aggregate as its stream stands
  def load(person_id, framework_id)
    @repository.load(PersonDevelopment::Aggregate.new, EventStreamNaming.person_development_stream(person_id, framework_id))
  end
end
