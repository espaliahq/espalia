# Event-Sourcing Standards

**Production data is live as of 2026-05-20.** Past events are real history. Read this before modifying events, aggregates, projections, sync handlers, or read models.

> **See also:**
> - [docs/runbooks/projection-rebuild.md](../runbooks/projection-rebuild.md) — operational steps for rebuilds
> - [docs/architecture/event-store.md](../architecture/event-store.md) — subscription/snapshot architecture
> - [docs/architecture/framework-aggregate.md](../architecture/framework-aggregate.md), [docs/architecture/person-development-aggregate.md](../architecture/person-development-aggregate.md) — aggregate-specific design

## Events are immutable

Once an event is published in production, its class, name, and payload shape are **frozen forever**.

- **Never** rename a field on an existing event.
- **Never** remove a field. New consumers can ignore it.
- **Never** rename or delete an event class.
- To evolve an event's shape, add a `RubyEventStore::Mappers::PipelineMapper` upcaster configured in [config/initializers/rails_event_store.rb](../../config/initializers/rails_event_store.rb). The upcaster reads the old shape and presents the new shape to handlers.

Adding a NEW event type is always safe. Adding a NEW field to a NEW event type is safe. Adding a field to an existing event is safe only if consumers tolerate its absence on older instances.

## Tenant metadata invariant

Every command dispatch in production code MUST wrap in:

```ruby
Rails.configuration.event_store.with_metadata(tenant_id: tenant.id) do
  # …command handler call…
end
```

All three aggregate repositories ([frameworks](../../app/contexts/frameworks/repository.rb), [person_development](../../app/contexts/person_development/repository.rb), [assessment_cycles](../../app/contexts/assessment_cycles/repository.rb)) already do this. Projections and the rebuild Replayer rely on `event.metadata[:tenant_id]` to scope operations. An event without it is invisible to per-tenant rebuilds.

Tests must obey the same invariant — either via the repository (which wraps automatically), or by passing `metadata: { tenant_id: @tenant.id }` when constructing raw events.

## Projection contract (replayable projections)

Every projection in [lib/projections/registry.rb](../../lib/projections/registry.rb) declares:

| Member | Purpose |
|---|---|
| `PROJECTION_NAME` (constant) | Stable identifier — natural key in `projection_versions.name`. Don't rename. |
| `CODE_VERSION` (constant, integer) | Bumped when reset!/replay would produce different state than before. |
| `.handled_events` | Array of event classes — drives both live subscription and replay's `of_type` filter. |
| `.reset!(tenant:)` | Idempotent truncation of every read model the projection writes, scoped to one tenant. |
| `#call(event)` | Same method the live subscriber uses. Must be idempotent for safe replay. |

**Each read-model table has exactly one projection writer.** This is the load-bearing rule for replays to be self-contained: dropping the table and replaying that projection's events must reproduce the same state — which is only true if no other projection contributes writes to the same table. See the anti-pattern entry below.

`reset!` ownership rules:
- Truncate every table the projection writes to. Each table is owned exclusively, so no other projection's `reset!` will touch it.
- Use `destroy_all` when you need Rails `dependent: :destroy` cascades. Use `delete_all` for flat tables (faster, skips callbacks).

Rebuild ordering:

- **`rebuild_all`** uses `Projections::GlobalReplayer.replay_all` — truncate everything up front, replay all events in global insertion order. Order in `Projections::Registry::REPLAYABLE` is conventional only; correctness comes from the live event order.
- **Sequential selective rebuilds** (running `rebuild[name]` back-to-back, or `REBUILD_ON_DEPLOY=a,b`): no semantic ordering requirement today because each projection owns its tables. The registry order is preserved as a defensive convention.

## Replay-mode side-effect suppression

Replay must not produce side effects beyond writing read models — no Turbo broadcasts, no job enqueuing, no ActionCable, no outbound HTTP.

```ruby
def broadcast_assessment_sync(event)
  return if Projections::Replayer.replay_mode?

  Turbo::StreamsChannel.broadcast_replace_to(...)
end
```

`Projections::Replayer.replay_mode?` is a thread-local flag set by [lib/projections/replayer.rb](../../lib/projections/replayer.rb) around the replay loop. Currently used by `CurrentAssessment` and `EvidenceCollection`. Any new side-effect-emitting projection handler must add the same guard.

## `CODE_VERSION` bump rules

Bump when **any** of these is true and there are past events in production to which the new logic would apply differently:

1. `reset!`'s truncate set changes (new read model owned; old one removed).
2. Any `handle_*` method computes a different read-model value for the same event payload.
3. A new event type is added to `handled_events` and past events of that type exist in the stream.
4. The serialized shape of any read-model column the projection writes is restructured.

Do **not** bump for:

- Pure additions of new handlers for new event types where no past events exist.
- Refactors that produce identical read-model state (extracted method, renamed variable, etc.).
- DB-schema-only changes (column addition with a default; index addition).

When you do bump, the predeploy guard (`events:projections:verify`) will fail the next deploy until the projection is rebuilt. See the runbook for the resolution flow (`REBUILD_ON_DEPLOY` env var, two-stage deploy).

## Sync handlers must not be replayed

Cross-stream handlers that dispatch domain commands — currently `AssessmentCycles::SyncHandlers::PersonEnrollmentSync` and `AssessmentCycles::SyncHandlers::AutoEnrollNewAssignments` — are deliberately NOT in `Projections::Registry::REPLAYABLE`. Replaying them would re-fire enrollments against already-applied state and raise from the aggregate (e.g. "already in a cycle").

If you add another sync-style cross-stream handler:

1. Subscribe it in [config/initializers/rails_event_store.rb](../../config/initializers/rails_event_store.rb) under the "cross-stream sync handlers" section.
2. Add a comment stating it must NOT be registered as a projection.
3. Do NOT add it to `Projections::Registry::REPLAYABLE`.
4. The `Projections::Registry` test ([test/lib/projections/registry_test.rb](../../test/lib/projections/registry_test.rb)) asserts the forbidden classes stay out — add yours there.

## Aggregate `on` handler / payload key drift

From Hard-Won Lesson 15 in [framework-explorer.md](framework-explorer.md):

> Aggregate `on(EventClass) { ... }` handlers must read the same payload keys the events were published with.

This is invisible while the aggregate is only a write-side validator (handlers' state is never read). The moment any code reads the aggregate's in-memory state — directly, or via a snapshot builder like `ExplorerGraph` — drift between published payload keys and consumed payload keys becomes a silent data bug.

Whenever you touch an aggregate handler or an event payload, audit both ends.

## Production data rules

**Production data is live.** Any destructive operation requires:

1. **Fresh Postgres snapshot** via Render dashboard. Verify the timestamp before proceeding. Do not rely on the daily auto-backup.
2. **Round-trip test locally**, OR rehearse on staging seeded from a recent prod snapshot when staging is available. There is no staging environment today — until one exists, lean harder on the local round-trip helpers (`test/support/projection_replay.rb`) and the canary-tenant step below.
3. **Canary tenant first** for projection rebuilds: `events:projections:rebuild[name,<canary_tenant_id>]`. Verify UI/API surfaces before global rebuild.
4. **Operator sign-off** for any new `CODE_VERSION` bump that touches a high-volume projection (`PublishedState`, `CurrentAssessment`).

See [docs/runbooks/projection-rebuild.md](../runbooks/projection-rebuild.md) for the full procedure.

## Schema vs logic changes

| Type | Predeploy handles? | Rebuild needed? |
|---|---|---|
| Schema migration (column add, index, table create) | Yes (`db:prepare`) | No |
| Backfill new column from past events | No | Yes — bump `CODE_VERSION` |
| Handler logic change | No | Usually yes — bump `CODE_VERSION` |
| New projection added | No | Yes — initial backfill |
| New event type, no past events | No | No (additive) |
| Existing event's payload shape | Use an upcaster, not a rebuild | No |

When in doubt, run the round-trip test for the affected projection locally and diff before/after read models. When staging exists, prefer rebuilding against a prod snapshot there.

## Anti-patterns

```ruby
# Bad — two projections writing to the same read-model table
class AssessmentCycles::Projections::CurrentState
  def handle_person_enrolled(event)
    Participant.upsert(cycle_id:, person_id:, enrolled_at: ...) # creates the row
  end
end

class PersonDevelopment::Projections::CurrentAssessment
  def handle_alignment_started(event)
    Participant.find_by(...).update!(alignment_started_at: ...) # updates same row
  end
end
# Replays now need manual ordering, each `reset!` can only truncate part of
# the table, and a fresh rebuild of either projection in isolation produces
# incomplete state. Model overlapping data as two tables joined at read
# time (e.g. `Enrollment` + `Progress` joined via a wrapper) so each table
# has a single writer.

# Bad — modifying a published event class
class Frameworks::Events::FrameworkCreated < RailsEventStore::Event
  # Renaming :name to :title here breaks every event ever published
end

# Bad — dispatching a command without tenant metadata
command_handler.create_framework(name: "X")
# Projection won't get tenant_id, replay can't find the event

# Bad — broadcast in projection without replay guard
def broadcast_assessment_sync(event)
  Turbo::StreamsChannel.broadcast_replace_to(...)  # fires during rebuilds — spams users
end

# Bad — reset! that's not idempotent
def self.reset!(tenant:)
  FrameworkState::Framework.first.destroy  # depends on row count
end

# Bad — adding a sync command-dispatching handler to REPLAYABLE
REPLAYABLE = {
  ...,
  "person_enrollment_sync" => "AssessmentCycles::SyncHandlers::PersonEnrollmentSync"
  # Replaying this re-dispatches JoinAssessmentCycle → aggregate raises
}

# Bad — bumping CODE_VERSION without actually changing handler/reset logic
CODE_VERSION = 2  # nothing changed; just thrashes the deploy guard
```
