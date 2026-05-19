# frozen_string_literal: true

# Replays events into a projection's read models.
#
# Uses RailsEventStore's canonical replay primitive:
# `event_store.read.of_type(handled_events).in_batches(N).each` — the same
# pattern `RubyEventStore::Projection#run` uses internally. Reads events of
# the projection's handled types across all streams in global insertion
# order; filters per-tenant via `event.metadata[:tenant_id]`.
#
# Calls `projection.call(event)` directly on a fresh projection instance.
# Does NOT publish events through the event store — live subscribers do not
# double-fire, and the excluded sync command-dispatching handlers
# (`PersonEnrollmentSync`, `AutoEnrollNewAssignments`) remain quiescent.
#
# Wraps replay in `ActsAsTenant.with_tenant` so projection `call` methods that
# write to acts_as_tenant-scoped read models pick the right tenant.
#
module Projections::Replayer
  BATCH_SIZE = 1_000
  REPLAY_MODE_KEY = :projections_replayer_replay_mode

  # True while a replay is in progress on the current thread. Projection
  # handlers MUST check this and suppress side effects beyond read-model
  # writes (e.g. Turbo Stream broadcasts, ActionCable, job enqueuing).
  #
  # See `docs/guidelines/event-sourcing.md` for the rule.
  def self.replay_mode?
    Thread.current[REPLAY_MODE_KEY] == true
  end

  # Replays every event the projection class handles for one tenant.
  #
  # @param projection_class [Class] must respond to `.handled_events`
  # @param tenant [Tenant] tenant whose events to replay
  # @param event_store [RailsEventStore::Client] defaults to global config
  # @return [Integer] events applied
  def self.replay(projection_class:, tenant:, event_store: Rails.configuration.event_store)
    projection = projection_class.new
    handled_events = projection_class.handled_events
    return 0 if handled_events.empty?

    applied = 0
    tenant_id_str = tenant.id.to_s

    with_replay_mode do
      ActsAsTenant.with_tenant(tenant) do
        # `.in_batches(N).each` reads in batches under the hood but yields
        # one event at a time. We can't use `.each_batch` and re-iterate
        # because tenant filtering happens per-event anyway.
        event_store.read.of_type(handled_events).in_batches(BATCH_SIZE).each do |event|
          next unless event.metadata[:tenant_id].to_s == tenant_id_str

          projection.call(event)
          applied += 1
        end
      end
    end

    applied
  end

  # @api private
  def self.with_replay_mode
    previous = Thread.current[REPLAY_MODE_KEY]
    Thread.current[REPLAY_MODE_KEY] = true
    yield
  ensure
    Thread.current[REPLAY_MODE_KEY] = previous
  end
end
