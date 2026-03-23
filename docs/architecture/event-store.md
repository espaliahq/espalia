# RES Event Store Configuration

> Read this when: configuring event subscriptions, adding new projections, working with snapshots, debugging event streams, or setting up new async handlers.

RES uses its own migrations. No custom event store tables needed.

```bash
rails generate rails_event_store_active_record:migration
rails db:migrate
```

This creates `event_store_events` and `event_store_events_in_streams` tables. Optimistic concurrency via stream version.

---

## Configuration

```ruby
# config/initializers/rails_event_store.rb
Rails.configuration.to_prepare do
  event_store = RailsEventStore::JSONClient.new(
    repository: RailsEventStoreActiveRecord::EventRepository.new(serializer: JSON),
    dispatcher: RubyEventStore::ComposedDispatcher.new(
      RubyEventStore::ImmediateAsyncDispatcher.new(
        scheduler: RailsEventStore::ActiveJobScheduler.new(serializer: JSON)
      ),
      RubyEventStore::Dispatcher.new
    )
  )

  # Synchronous projections (same transaction)
  event_store.subscribe(
    Frameworks::Projections::PublishedState.new,
    to: Frameworks::Events.all_content_events
  )
  event_store.subscribe(
    PersonDevelopment::Projections::CurrentAssessment.new,
    to: PersonDevelopment::Events.all_rating_events
  )
  event_store.subscribe(
    PersonDevelopment::Projections::GrowthPlan.new,
    to: PersonDevelopment::Events.all_growth_events
  )
  event_store.subscribe(
    PersonDevelopment::Projections::EvidenceCollection.new,
    to: PersonDevelopment::Events.all_evidence_events
  )

  # Async handlers (via Solid Queue)
  event_store.subscribe(
    Integrations::Notifications::AssessmentNotifier,
    to: [PersonDevelopment::Events::SelfRated,
         PersonDevelopment::Events::FullAlignmentCompleted]
  )
  event_store.subscribe(
    Reporting::Projections::GapAnalysis,
    to: [PersonDevelopment::Events::FullAlignmentCompleted]
  )

  Rails.configuration.event_store = event_store
end
```

---

## Snapshot Strategy

Use `AggregateRoot::SnapshotRepository` with snapshots stored in a separate RES stream (`*_snapshots`). Snapshot at every `FrameworkVersionPublished` and `FullAlignmentCompleted`.

```ruby
# app/contexts/frameworks/repository.rb
module Frameworks
  class Repository
    def initialize(event_store: Rails.configuration.event_store)
      @repo = AggregateRoot::SnapshotRepository.new(
        event_store,
        interval: 50  # snapshot every 50 events
      )
    end

    def with_framework(framework_id, &block)
      stream = EventStreamNaming.framework_stream(framework_id)
      @repo.with_aggregate(Aggregate.new, stream, &block)
    end
  end
end
```

---

## RES Browser

Mount for debugging (restricted to global admins in production):

```ruby
# config/routes.rb
Rails.application.routes.draw do
  authenticate :user, ->(u) { u.global_admin? } do
    mount RailsEventStore::Browser => "/res"
  end
end
```
