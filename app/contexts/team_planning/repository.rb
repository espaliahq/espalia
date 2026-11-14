# frozen_string_literal: true

# Loads and stores plan aggregates via RailsEventStore.
#
# Builds stream names through EventStreamNaming and puts the tenant on every
# event's metadata, as the other contexts' repositories do.
#
class TeamPlanning::Repository
  # @param event_store [RailsEventStore::JSONClient] defaults to global config
  def initialize(event_store: Rails.configuration.event_store)
    @event_store = event_store
    @repository = AggregateRoot::Repository.new(event_store)
  end

  # Loads a plan, yields it, and stores any new events, holding the stream's
  # lock until the transaction ends.
  #
  # @param plan_id [String]
  # @yield [TeamPlanning::PlanAggregate]
  # @return [TeamPlanning::PlanAggregate] the plan as stored
  # @raise [ArgumentError] if no tenant context is available
  def with_plan(plan_id, &block)
    stream = EventStreamNaming.plan_stream(plan_id)
    plan = TeamPlanning::PlanAggregate.new
    with_tenant_metadata do
      ActiveRecord::Base.transaction do
        lock_stream(stream)
        @repository.with_aggregate(plan, stream, &block)
      end
    end
    plan
  end

  private

  # The expected version catches a write only between load and store; the
  # lock also holds a check the handler makes against the loaded state.
  def lock_stream(stream)
    sql = ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_advisory_xact_lock(hashtextextended(?, 0))", stream ])
    ActiveRecord::Base.connection.execute(sql)
  end

  def with_tenant_metadata(&block)
    tenant = ActsAsTenant.current_tenant
    raise ArgumentError, "No tenant context available" unless tenant

    @event_store.with_metadata({ tenant_id: tenant.id }, &block)
  end
end
