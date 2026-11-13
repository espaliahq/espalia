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
  # @param plan [OrgGraph::PlanReference, nil] stamped on every event written
  # @param cause_id [String, nil] the correlation id every event written shares
  # @yield [OrgGraph::PersonAggregate] the loaded aggregate
  # @raise [ArgumentError] if no tenant context is available
  def with_person(person_id, plan: nil, cause_id: nil, &block)
    with_locked_stream(EventStreamNaming.person_stream(person_id), cause_id) do |stream|
      @repository.with_aggregate(OrgGraph::PersonAggregate.new, stream) do |person|
        person.within_plan(plan, &block)
      end
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
  # @param plan [OrgGraph::PlanReference, nil] stamped on every event written
  # @param cause_id [String, nil] the correlation id every event written shares
  # @yield [OrgGraph::StructureAggregate] the loaded aggregate
  # @raise [ArgumentError] if no tenant context is available
  def with_structure(plan: nil, cause_id: nil, &block)
    with_locked_stream(EventStreamNaming.org_structure_stream, cause_id) do |stream|
      @repository.with_aggregate(OrgGraph::StructureAggregate.new, stream) do |structure|
        structure.within_plan(plan, &block)
      end
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
  # so a caller that checks a read model first needs this lock to hold. The
  # transaction also holds the sync handlers the write sets off, since RES
  # commits the events before its subscribers run.
  def with_locked_stream(stream, cause_id)
    with_tenant_metadata(cause_id) do
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

  # A cause replaces the request's correlation id, so every event one plan
  # approval writes, a sync handler's included, reads as one change.
  def with_tenant_metadata(cause_id, &block)
    tenant = ActsAsTenant.current_tenant
    raise ArgumentError, "No tenant context available" unless tenant

    @event_store.with_metadata({ tenant_id: tenant.id, correlation_id: cause_id.presence }.compact, &block)
  end
end
