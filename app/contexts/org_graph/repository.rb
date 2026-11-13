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
    with_locked_stream(EventStreamNaming.person_stream(person_id)) do |stream|
      @repository.with_aggregate(OrgGraph::PersonAggregate.new, stream, &block)
    end
  end

  # Loads a person's aggregate without storing anything.
  #
  # @param person_id [String] UUID of the person
  # @return [OrgGraph::PersonAggregate]
  def load_person(person_id)
    @repository.load(OrgGraph::PersonAggregate.new, EventStreamNaming.person_stream(person_id))
  end

  # Loads the tenant's structure aggregate, yields it, and stores any new events.
  #
  # @yield [OrgGraph::StructureAggregate] the loaded aggregate
  # @raise [ArgumentError] if no tenant context is available
  def with_structure(&block)
    with_locked_stream(EventStreamNaming.org_structure_stream) do |stream|
      @repository.with_aggregate(OrgGraph::StructureAggregate.new, stream, &block)
    end
  end

  # Holds the write lock on a person's stream until the enclosing transaction
  # ends, as {#with_person} does, so a check made after it can't be overtaken.
  #
  # @param person_id [String] UUID of the person
  def lock_person(person_id) = lock_stream(EventStreamNaming.person_stream(person_id))

  # Holds the write lock on the tenant's structure stream, as {#with_structure} does.
  def lock_structure = lock_stream(EventStreamNaming.org_structure_stream)

  private

  # The stream's expected version catches a write only between load and store,
  # so a caller that checks a read model first needs this lock to hold.
  def with_locked_stream(stream)
    with_tenant_metadata do
      ActiveRecord::Base.transaction do
        lock_stream(stream)
        yield stream
      end
    end
  end

  def lock_stream(stream)
    sql = ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_advisory_xact_lock(hashtextextended(?, 0))", stream ])
    ActiveRecord::Base.connection.execute(sql)
  end

  def with_tenant_metadata(&block)
    tenant = ActsAsTenant.current_tenant
    raise ArgumentError, "No tenant context available" unless tenant

    @event_store.with_metadata(tenant_id: tenant.id, &block)
  end
end
