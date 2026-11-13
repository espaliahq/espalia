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

**When a new field narrows what an event means, its absence must keep the old meaning — in every consumer.** Per-role alignment (ADR-22) added `role_id` and `cell_keys` to `AlignmentStarted`: a new start freezes only its role's cells, but a historical one, carrying neither, froze the whole assessment. The aggregate's `on` handler replays a missing `cell_keys` as "every cell", and the projection writes `whole_assessment: true` so the read side agrees — otherwise every open cycle that had started alignment would silently thaw on its next load. Test it by replaying the old event shape, not by constructing new events with the field set to nil.

## Tenant metadata invariant

Every command dispatch in production code MUST wrap in:

```ruby
Rails.configuration.event_store.with_metadata(tenant_id: tenant.id) do
  # …command handler call…
end
```

All four aggregate repositories ([frameworks](../../app/contexts/frameworks/repository.rb), [person_development](../../app/contexts/person_development/repository.rb), [assessment_cycles](../../app/contexts/assessment_cycles/repository.rb), [org_graph](../../app/contexts/org_graph/repository.rb)) already do this. Projections and the rebuild Replayer rely on `event.metadata[:tenant_id]` to scope operations. An event without it is invisible to per-tenant rebuilds.

Tests must obey the same invariant — either via the repository (which wraps automatically), or by passing `metadata: { tenant_id: @tenant.id }` when constructing raw events.

## Attribution invariant — every event carries provenance

Every event MUST be attributable to *who* triggered it, *how*, and *as part of which logical operation*. This is non-negotiable: an unattributed event is a permanent hole in the audit trail — events are immutable, so provenance not captured at write time can never be back-filled.

There are **two layers**, and the distinction is load-bearing — put each fact in the right place:

### 1. Provenance → RES metadata (universal, automatic)

Cross-cutting "who/how/which-request" provenance lives in **metadata**, set once at the request/job boundary via [`AuditMetadata`](../../app/services/audit_metadata.rb) and applied to *every* event automatically — no per-event or per-handler wiring:

| Metadata key | Meaning | Seeded by |
|---|---|---|
| `acting_via` | `web` / `mcp` / `hris` / `slack` / `feedback_exchange` / `system` — the surface (`slack` = the feedback modal's submission; `feedback_exchange` = feedback imported from a peer system, written as its real author; `system` = a scheduled job acting on its own, e.g. the evidence-request reminder sweep) | `ApplicationController`, `Mcp::ServerController`, HRIS adapter, `Slack::Feedback`, `FeedbackExchange::Importer`, sweep jobs |
| `actor_id` | uuid of the Person who triggered the write (nil for system syncs) | same |
| `client_application_id` | Doorkeeper application uuid (MCP only) | `Mcp::ServerController` |
| `correlation_id` | id shared by every event one request/sync produced | request id (web/MCP) · job id or fresh uuid (HRIS) |

`Operations::Base#call` wraps `perform` in `AuditMetadata.wrap_event_store`, so any event a command handler publishes inside an Operation inherits all four. **You almost never touch this layer** — it already covers all events. Symbols are stringified at the event-store boundary (RES `Metadata` rejects Symbol values).

### 2. Domain attribution → event payload (selective, explicit)

When the actor is also a **first-class domain fact a read model surfaces** — e.g. *which manager* rated you, who authored evidence, who approved a suggestion — model it ADDITIONALLY as an explicit payload field (`rated_by_id`, `author_id`, `reviewer_id`, `started_by_id`, …) and a read-model column. Reasons it goes in payload, not just metadata:

- Projections read `event.data`, not metadata — a column the UI renders must be fed from payload.
- It's domain history with real weight, not ops telemetry, and should survive independently of the provenance layer.
- Metadata `actor_id` is absent on non-request paths (replay, rake, seeds); a domain command should know its actor explicitly.

The well-attributed events to copy: Evidence (`author_id`/`edited_by_id`/`relinked_by_id`/`withdrawn_by_id`), Comments (`author_id`/`edited_by_id`/`deleted_by_id`), Suggestions (`author_id`/`reviewer_id`), collaborator + cycle-lifecycle + alignment-milestone events (`added_by`, `defined_by`, `started_by_id`, `completed_by_id`).

**Adding a payload attribution field to an existing event is additive-safe** (older instances simply lack it) — projections and views MUST tolerate nil for historical events (fall back to a generic label like "Manager", never crash). Pure structural framework events (`CapabilityAdded`, `LevelAdded`, …) stay metadata-only — they have no read-model actor surface.

When you add a new event or command, decide deliberately: metadata provenance is automatic; add a payload actor field iff a read model will surface it.

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

**Never decide a row from another projection's mutable table.** A rebuild replays your events against that table as it *ended*, not as it stood when each event was written, so an event from before a change is judged by the state after it. `CurrentAssessment` once read the enrollment snapshot to decide which alignment was the home one; after a mid-cycle transfer a rebuild re-homed history that live had filed correctly ([#687](https://github.com/mr-yum/growth-os/issues/687)). Track the fact from your own events instead, as the projection now tracks `home_role_id`. A fact that never changes after it is written, such as a cycle's framework, is safe to read. Prove it with a round-trip test that moves the other table to its final state before the rebuild.

`reset!` ownership rules:
- Truncate every table the projection writes to. Each table is owned exclusively, so no other projection's `reset!` will touch it.
- Use `destroy_all` when you need Rails `dependent: :destroy` cascades. Use `delete_all` for flat tables (faster, skips callbacks).

Rebuild ordering:

- **`rebuild_all`** uses `Projections::GlobalReplayer.replay_all` — truncate everything up front, replay all events in global insertion order. Order in `Projections::Registry::REPLAYABLE` is conventional only; correctness comes from the live event order.
- **Sequential selective rebuilds** (running `rebuild[name]` back-to-back, or `REBUILD_ON_DEPLOY=a,b`): no semantic ordering requirement today because each projection owns its tables. The registry order is preserved as a defensive convention.

## Externally-addressable read-model identity must be deterministic

**Any read-model row addressed from outside by its primary key — a REST route param, an MCP resource URI (`assessment://<id>`), a bookmark, an id an MCP client cached — MUST have a PK that is a pure function of event-sourced data, so `reset!` + replay reproduces the same id.** A row whose PK is minted fresh at projection time (the default `SecureRandom.uuid_v7` from `ApplicationRecord`) gets a *new* id on every rebuild; every URL that captured the old id then 404s. This caused a production incident (evidence POSTed to a now-stale `PersonFrameworkAssignment` id surfaced as a 500).

Two compliant patterns:

1. **PK == an event-carried id.** The creating event carries an id minted at command time (`EvidenceItem` ← `evidence_id`, `PersonDevelopmentComment` ← `comment_id`); the projection sets `find_or_initialize_by(id: event.data[:…])`.
2. **PK derived deterministically from the natural key** via the [`DeterministicId`](../../app/models/concerns/deterministic_id.rb) concern — `deterministic_id_from :person_id, :framework_id` → `id = UUIDv5(namespace, "Model:val/val")`. Use when there's no single event id but the natural key is stable and singular (`PersonFrameworkAssignment`, `ManagerAssessmentDelegation`).

A read model addressed only by an **event-sourced domain column** (`framework_id`, `capability_id`, `cycle_id`, …) is already stable — routes use that column, not the surrogate PK, so the random PK never escapes.

When adding a read model, decide its external-identity strategy deliberately. The `DeterministicId` derivation (namespace, attribute set, order, format) is **frozen once any row exists in production** — historical rows' ids depend on it, so changing it reissues them on the next rebuild. Treat it like an immutable event shape.

**Enforced by the round-trip guard.** `ProjectionReplayHelpers#rows(scope, stable_id: true)` includes `id` in the snapshot for stable-PK tables, and the projection round-trip tests assert the snapshot is identical across `reset!` + replay. A reverted concern or a new addressable table with a random PK fails CI rather than silently reissuing ids.

## Rating reads are role-scoped

A rating belongs to a cell, not a role (ADR-22), so `assessment_level_ratings` has no role column. Any query over it outside the `CurrentAssessment` projection must pass through `AssessmentLevelRating.within(Assessments::RoleScope…)` or announce `.across_all_roles`; the `Espalia/RatingsMustBeRoleScoped` cop enforces it. The rule and its exemptions live in [assessments/role-lens.md → Role-scoped reads](assessments/role-lens.md). A new read model that stores rating-derived state inherits the rule: decide which role it reads for before writing the projection.

## Re-keying on `FrameworkVersionMigrated` merges on collision

Any read model keyed by `capability_stable_id` under a unique index must merge on collision in its `FrameworkVersionMigrated` handler. An `evolved` survivor can already be rated/linked by the same person at the same natural key, so a plain `update_all` re-key trips the index and rolls back the publish. The two existing handlers resolve it differently, so copy the one that matches your model: `rekey_ratings` keeps the colliding rating under the retiring id, flagged `capability_merged`; `rekey_links` keeps (or revives) the survivor link and removes the retiring one as `framework_migration_merged`. See ADR-17 in [adrs.md](../architecture/adrs.md).

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

**A brand-new registered projection is "stale" too.** `verify` treats a projection with no `projection_versions` row as never rebuilt and fails the deploy, so adding one to `Projections::Registry` is a deploy step (`REBUILD_ON_DEPLOY=<name>` or `mark_rebuilt`) even when no historical event exists. Handing a new table to an existing projection avoids registering and stamping a separate one — declared explorations went to `CurrentAssessment` for this reason, with new event types and no history. If historical events must populate the table, bump that projection's `CODE_VERSION` and rebuild it all the same.

When you do bump, the predeploy guard (`events:projections:verify`) will fail the next deploy until the projection is rebuilt. See the runbook for the resolution flow (`REBUILD_ON_DEPLOY` env var, two-stage deploy).

## Sync handlers must not be replayed

Cross-stream handlers that dispatch domain commands — currently `AssessmentCycles::SyncHandlers::PersonEnrollmentSync`, `AssessmentCycles::SyncHandlers::AutoEnrollNewAssignments`, `AssessmentCycles::SyncHandlers::FrameworkVersionRollSync`, and `Frameworks::SyncHandlers::FrameworkVersionMigrationSync` — are deliberately NOT in `Projections::Registry::REPLAYABLE`. Replaying them would re-fire enrollments / re-roll cycles / re-migrate person streams against already-applied state. The aggregates each carry their own idempotency guard so an accidental replay is mostly a no-op, but the registry guard at `test/lib/projections/registry_test.rb` keeps them out at the source.

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
