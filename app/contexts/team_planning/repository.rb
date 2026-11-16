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
  ensure
    CurrentPlanReads.memo&.clear
    CurrentPlanReads.forget_copies
  end

  # Holds the plan's lock while the block runs, so a write that first reads the
  # plan's state sees no other write land between its read and its store.
  # {#with_plan} inside the block takes the same lock again, which Postgres allows.
  #
  # @param plan_id [String]
  # @return [Object] what the block returns
  def holding_plan(plan_id)
    ActiveRecord::Base.transaction do
      lock_stream(EventStreamNaming.plan_stream(plan_id))
      yield
    end
  end

  # Loads a plan to read, taking no lock and storing nothing.
  #
  # @param plan_id [String]
  # @return [TeamPlanning::PlanAggregate]
  # @raise [ArgumentError] if no tenant context is available
  def load_plan(plan_id)
    current_tenant!
    @repository.load(TeamPlanning::PlanAggregate.new, EventStreamNaming.plan_stream(plan_id))
  end

  # @param plan_id [String]
  # @return [Hash, nil] the pricing inputs the plan's archive copied, or nil
  #   when it was restored since, never copied any, its key is gone, or no
  #   key can be read here, as on a copy of the database without its credentials
  def prices_frozen(plan_id)
    return unless PlanKeyStore.available?

    last = @event_store.read.stream(EventStreamNaming.plan_stream(plan_id)).backward
                       .of_type([ TeamPlanning::Events::PlanPricesFrozen, TeamPlanning::Events::PlanRestored ]).first
    return unless last.is_a?(TeamPlanning::Events::PlanPricesFrozen)

    CurrentPlanReads.copy(last.event_id) do
      inputs = last.data[:inputs]
      inputs.reveal unless inputs.nil? || inputs.removed?
    end
  end

  # The aggregate never holds a shreddable value, so its changes come
  # without one. A reader that shows the value swaps each change whose end
  # state is sealed for the event as stored, still sealed. A note alone
  # decides nothing a reader of the end state shows, so it isn't fetched.
  #
  # @param changes [Hash{Array(String, String) => TeamPlanning::Events::Change}] as {PlanAggregate#winning_changes} gives them
  # @return [Hash{Array(String, String) => TeamPlanning::Events::Change}] the same keys, in the same order
  def sealed(changes)
    ids = changes.values.select { it.class.seals_end_state? }.map(&:event_id)
    return changes if ids.empty?

    stored = @event_store.read.events(ids).to_a.index_by(&:event_id)
    changes.transform_values { stored.fetch(it.event_id, it) }
  end

  private

  # The expected version catches a write only between load and store; the
  # lock also holds a check the handler makes against the loaded state.
  def lock_stream(stream)
    sql = ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_advisory_xact_lock(hashtextextended(?, 0))", stream ])
    ActiveRecord::Base.connection.execute(sql)
  end

  def with_tenant_metadata(&block)
    @event_store.with_metadata({ tenant_id: current_tenant!.id }, &block)
  end

  def current_tenant!
    ActsAsTenant.current_tenant or raise ArgumentError, "No tenant context available"
  end
end
