# frozen_string_literal: true

# Loads and saves the one aggregate a tenant keeps in a single stream, under
# that stream's lock. A subclass names the aggregate and the stream.
#
# Every write takes a Postgres advisory lock on the stream name, so two
# commands, or a command and a projection's reset, never interleave.
#
# @example
#   class AccountGrants::Repository < TenantStreams::Repository
#     private
#     def new_aggregate = AccountGrants::Aggregate.new
#     def stream_name(tenant) = EventStreamNaming.account_grants_stream(tenant:)
#   end
class TenantStreams::Repository
  # @param event_store [RubyEventStore::Client]
  def initialize(event_store: Rails.configuration.event_store)
    @event_store = event_store
    @repository = AggregateRoot::Repository.new(event_store)
  end

  # Loads the aggregate under the lock, yields it, then appends what it applied.
  #
  # @yieldparam aggregate [AggregateRoot]
  # @return [AggregateRoot] the aggregate, with its new events applied
  def with_aggregate(&block)
    tenant = current_tenant!
    aggregate = new_aggregate
    @event_store.with_metadata({ tenant_id: tenant.id }) do
      ActiveRecord::Base.transaction do
        lock_stream(tenant)
        @repository.with_aggregate(aggregate, stream_name(tenant), &block)
      end
    end
    aggregate
  end

  # Yields the aggregate as it stands, holding the lock until the block
  # returns, so a projection's reset can write from it without a command
  # landing in between.
  #
  # @yieldparam aggregate [AggregateRoot]
  # @return [Object] the block's value
  def reading_locked
    tenant = current_tenant!
    ActiveRecord::Base.transaction do
      lock_stream(tenant)
      yield @repository.load(new_aggregate, stream_name(tenant))
    end
  end

  # @return [AggregateRoot] the aggregate as it stands, read without the lock
  def load_aggregate
    @repository.load(new_aggregate, stream_name(current_tenant!))
  end

  private

  # @return [AggregateRoot] a fresh aggregate for this stream
  def new_aggregate
    raise NotImplementedError, "#{self.class} must define #new_aggregate"
  end

  # @param tenant [Tenant]
  # @return [String] the stream name, from EventStreamNaming
  def stream_name(tenant)
    raise NotImplementedError, "#{self.class} must define #stream_name"
  end

  def lock_stream(tenant)
    sql = ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_advisory_xact_lock(hashtextextended(?, 0))", stream_name(tenant) ])
    ActiveRecord::Base.connection.execute(sql)
  end

  def current_tenant!
    ActsAsTenant.current_tenant or raise ArgumentError, "No tenant context available"
  end
end
