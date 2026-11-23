# frozen_string_literal: true

# Loads and stores a tenant's account grants via RailsEventStore.
#
# Builds the stream name through EventStreamNaming and puts the tenant on
# every event's metadata, as the other contexts' repositories do.
#
class AccountGrants::Repository
  # @param event_store [RailsEventStore::JSONClient] defaults to global config
  def initialize(event_store: Rails.configuration.event_store)
    @event_store = event_store
    @repository = AggregateRoot::Repository.new(event_store)
  end

  # Loads the tenant's grants, yields them, and stores any new events,
  # holding the stream's lock until the transaction ends.
  #
  # @yield [AccountGrants::Aggregate]
  # @return [AccountGrants::Aggregate] the grants as stored
  # @raise [ArgumentError] if no tenant context is available
  def with_grants(&block)
    stream = EventStreamNaming.account_grants_stream(tenant: current_tenant!)
    grants = AccountGrants::Aggregate.new
    @event_store.with_metadata({ tenant_id: current_tenant!.id }) do
      ActiveRecord::Base.transaction do
        lock_stream(stream)
        @repository.with_aggregate(grants, stream, &block)
      end
    end
    grants
  end

  # Loads the tenant's grants to read, taking no lock and storing nothing.
  #
  # @return [AccountGrants::Aggregate]
  # @raise [ArgumentError] if no tenant context is available
  def load_grants
    @repository.load(AccountGrants::Aggregate.new, EventStreamNaming.account_grants_stream(tenant: current_tenant!))
  end

  private

  # The expected version only catches a write between load and store; the
  # lock also holds the no-op check a duplicate add makes.
  def lock_stream(stream)
    sql = ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_advisory_xact_lock(hashtextextended(?, 0))", stream ])
    ActiveRecord::Base.connection.execute(sql)
  end

  def current_tenant!
    ActsAsTenant.current_tenant or raise ArgumentError, "No tenant context available"
  end
end
