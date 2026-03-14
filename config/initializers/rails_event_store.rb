# frozen_string_literal: true

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
    )
  )

  # ── Synchronous projections (same transaction) ──
  # Subscriptions will be added here as aggregates are implemented.
  # Example:
  #   event_store.subscribe(
  #     Frameworks::Projections::PublishedState.new,
  #     to: Frameworks::Events.all_content_events
  #   )

  # ── Async handlers (via SolidQueue) ──
  # Subscriptions will be added here as integrations are implemented.
  # Example:
  #   event_store.subscribe(
  #     Integrations::Notifications::AssessmentNotifier,
  #     to: [PersonDevelopment::Events::SelfRated]
  #   )

  Rails.configuration.event_store = event_store
end
