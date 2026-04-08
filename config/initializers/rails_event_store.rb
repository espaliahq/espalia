# frozen_string_literal: true

require "aggregate_root"

# Configures RailsEventStore with:
# - ActiveRecord-backed PostgreSQL repository
# - JSON serialization
# - ComposedDispatcher: sync handlers (same transaction) + async handlers (SolidQueue)
#
# Access via: Rails.configuration.event_store
#
Rails.configuration.to_prepare do
  event_store = RailsEventStore::JSONClient.new(
    repository: RailsEventStoreActiveRecord::EventRepository.new(serializer: JSON),
    message_broker: RubyEventStore::Broker.new(
      subscriptions: RubyEventStore::Subscriptions.new,
      dispatcher: RubyEventStore::ComposedDispatcher.new(
        RailsEventStore::AfterCommitAsyncDispatcher.new(
          scheduler: RailsEventStore::ActiveJobScheduler.new(serializer: JSON)
        ),
        RubyEventStore::Dispatcher.new
      )
    ),
  )

  # ── Synchronous projections (same transaction) ──
  event_store.subscribe(
    Frameworks::Projections::PublishedState.new,
    to: Frameworks::Projections::PublishedState.handled_events
  )

  event_store.subscribe(
    PersonDevelopment::Projections::CurrentAssessment.new,
    to: PersonDevelopment::Projections::CurrentAssessment.handled_events
  )

  event_store.subscribe(
    AssessmentCycles::Projections::CurrentState.new,
    to: AssessmentCycles::Projections::CurrentState.handled_events
  )

  # ── Synchronous cross-stream sync handlers ──
  # NOTE: PersonEnrollmentSync dispatches PersonDevelopment commands,
  # so it MUST NOT be registered as a projection — running it twice
  # would raise "already in a cycle" from the PersonDev aggregate.
  event_store.subscribe(
    AssessmentCycles::SyncHandlers::PersonEnrollmentSync.new,
    to: AssessmentCycles::SyncHandlers::PersonEnrollmentSync.handled_events
  )

  # AutoEnrollNewAssignments dispatches the AssessmentCycles enroll command
  # (which then cascades via PersonEnrollmentSync to PersonDev). Same
  # projection-rebuild hazard as above — MUST NOT be registered as a projection.
  event_store.subscribe(
    AssessmentCycles::SyncHandlers::AutoEnrollNewAssignments.new,
    to: AssessmentCycles::SyncHandlers::AutoEnrollNewAssignments.handled_events
  )

  # ── Async handlers (via SolidQueue) ──
  # Subscriptions will be added here as integrations are implemented.
  # Example:
  #   event_store.subscribe(
  #     Integrations::Notifications::AssessmentNotifier,
  #     to: [PersonDevelopment::Events::SelfRated]
  #   )

  Rails.configuration.event_store = event_store
end
