# Runbook: Rebuilding a Projection

Use this when a code change makes a projection's current read model state inconsistent with how the projection *would* now compute it from the event stream. Predeploy migrations handle schema; rebuilds handle **logic**.

> **Production data is live.** Read [Production safety](#production-safety) before running any rebuild against production.

> **See also:** [docs/guidelines/event-sourcing.md](../guidelines/event-sourcing.md) for the projection contract, `CODE_VERSION` bump rules, and the upcaster-vs-rebuild decision.

## Production safety

| Rule | What to do |
|---|---|
| **Snapshot first, always** | Take a manual Postgres snapshot via the Render dashboard before any `reset!` / `rebuild`. Verify the timestamp. The daily auto-backup may be up to 24h stale — do not rely on it as the sole line of defence. |
| **Rehearse before running on prod** | If a staging environment exists, run the same rebuild there against a recent prod snapshot. Today there is no staging — instead, run the projection's round-trip test locally (`test/support/projection_replay.rb` helpers) and rely on the canary-tenant step below. Stand up staging before any high-risk rebuild. |
| **Canary tenant first** | Run `events:projections:rebuild[<name>,<canary_tenant_id>]` against one low-impact tenant. Eyeball their UI / API surfaces. Only then run the global form. Single-tenant rebuild does **not** stamp `projection_versions`; the global form does. |
| **Quiesce writes for high-churn projections** | For `PublishedState` / `CurrentAssessment` under load, pause command handlers or run during a quiet window. Live events arriving mid-replay get projected by the live subscriber *and* counted by the task — same event applied twice. |
| **Rollback is restore-from-snapshot** | Events are immutable; the event store doesn't need rolling back. Read models do. Rollback = restore the snapshot you took in step 1. The round-trip test (per projection) guarantees a clean rebuild reproduces identical state. |
| **No `mark_rebuilt` without rebuilding** | The escape valve writes the current `CODE_VERSION` to the DB *without* doing the rebuild. Footgun. Only use when you have verifiably rebuilt by other means (e.g. via a one-off data migration). |
| **RES event store integrity check** | Before any rebuild: `Rails.configuration.event_store.read.limit(1).count > 0` and a sample event has `:tenant_id` in metadata. A corrupted event store produces garbage read models AND stamps a clean version row — a trap. |

## How the predeploy guard works

Every replayable projection declares `CODE_VERSION` (integer). The `projection_versions(name PK, version, applied_at)` table records the last version each projection was rebuilt at. Predeploy ([bin/render-predeploy](../../bin/render-predeploy)) runs `events:projections:verify` after migrations — if any projection's `CODE_VERSION` constant exceeds the row in `projection_versions`, predeploy exits non-zero and Render aborts the deploy.

The version is a human-decided signal: bump it when handler logic or `reset!` semantics change in a way that requires reprocessing past events. See [event-sourcing.md](../guidelines/event-sourcing.md) for bump rules.

## When you need a rebuild

| Change | Rebuild needed? |
|---|---|
| Added a column to a read model, populated by future events only | No — backfill via SQL or skip |
| Added a column whose value depends on past events | Yes — bump `CODE_VERSION` |
| Changed handler logic (different field written, new derivation) | Yes — bump `CODE_VERSION` |
| Added a new projection that needs historical state | Yes — initial backfill |
| Renamed an event field | No — add an upcaster |
| New read-model index | No — DDL only, predeploy covers it |

If you're not sure, run the projection's round-trip test locally (`test/support/projection_replay.rb`) — it snapshots read-model state, replays, and diffs. When staging exists, prefer rebuilding there against a prod snapshot.

## When you must NOT rebuild

The sync handlers in [config/initializers/rails_event_store.rb](../../config/initializers/rails_event_store.rb) marked with `MUST NOT be registered as a projection` (`PersonEnrollmentSync`, `AutoEnrollNewAssignments`) dispatch domain commands. Replaying them would re-fire enrollments against already-enrolled people and raise from the aggregate. The `Projections::Registry::REPLAYABLE` allowlist excludes them by design.

## Deploy choreography

Because predeploy hard-fails on a stale projection, a `CODE_VERSION` bump can't ship until the rebuild has stamped the version row. Render's pre-deploy phase runs against the **new image**; the Shell tab and one-off jobs run against the **currently-deployed image**. Three viable paths:

### Path A — single deploy with `REBUILD_ON_DEPLOY` (default)

Use when the rebuild fits comfortably inside the predeploy window (small to medium projections).

1. PR bumps `CODE_VERSION` and ships the handler change.
2. **Before triggering the deploy**, set the env var on the Render web service:
   ```
   REBUILD_ON_DEPLOY=frameworks/published_state
   ```
   Comma-separated for multiple projections.
3. Trigger the deploy. Predeploy script:
   - Runs migrations.
   - Sees `REBUILD_ON_DEPLOY`, runs `events:projections:rebuild_if_stale[<name>]` for each (against the new image): a rebuild only when the stamped version is behind `CODE_VERSION`. This stamps `projection_versions`.
   - Runs `events:projections:verify` — passes.
   - Traffic swaps.
4. **Remove the env var** after deploy succeeds (it lives in the `growthos-shared` env group on Render). A forgotten variable is inert once the stamp is current, but keep the group honest.

**The rebuild is a visible outage window.** Predeploy runs against the production database while the previous release is still serving traffic, and a rebuild starts by truncating the projection's tables. For `person_development/current_assessment` that is every rating, assignment and progress row: for the one to two minutes the replay takes, every assessment in the app reads as empty, then fills back in. Schedule a deploy that rebuilds accordingly, and never leave the variable set — it was once left for four deploys and each one blanked assessments (2026-09-15).

#### Recorded: `person_development/current_assessment` v8 (per-role alignment, ADR-22)

Path A: `REBUILD_ON_DEPLOY=person_development/current_assessment`, removed from `growthos-shared` once the deploy is live. What the rebuild changes:

- It **backfills `assessment_cycle_role_alignments`** — one row per historical alignment, all of them the home role's, marked `whole_assessment` (they froze every cell and still do). Without the rows the read side would freeze only the home role's cells while the aggregate freezes all of them, and a lens-only pill would render editable over a write the aggregate refuses — `events:projections:verify` blocks exactly that deploy.
- It **re-derives `started`**: a participation whose only human ratings were made through a lens (`via_role_id`, phase 2) on cells the home role doesn't read goes back to `enrolled`. Ratings made on the record keep starting it whatever the framework says today. The cohort report and the list's chips read it.

Measured on the seeded dev database (7,298 handled events, one tenant): **~45 s wall** for `events:projections:rebuild[person_development/current_assessment]`, Rails boot included (about 6 ms an event; the `started` check adds a role-scope read only until a participation has started). Scale that by the production event count (pre-flight step 4) before choosing Path A: every assessment reads as empty for that long while the previous release serves traffic, so deploy in a quiet window.

#### Recorded: `person_development/current_assessment` v9 (home role at the join, [#673](https://github.com/mr-yum/growth-os/issues/673))

Path A, as v8. The rebuild fills `assessment_cycle_progress.joined_role_id` / `joined_level_id` from the assignment at each `JoinedAssessmentCycle`, then files a role-less (pre-ADR-22) alignment start, completion or re-open under that role, as the aggregate does. Only a participant who changed role mid-cycle after such an event reads differently: their historical alignment row moves from the new role to the one they joined as, still `home`. A progress row with no `joined_role_id` falls back to the enrollment snapshot, the v8 behaviour.

Measured on the seeded dev database (7,734 handled events, one tenant): **57 s wall**, Rails boot included.

### Path B — two-stage deploy (large rebuilds)

Use when the rebuild won't fit in predeploy's window (Render's default is generous but not unlimited; check Render docs for your plan).

1. **PR 1**: ship the handler change with **no `CODE_VERSION` bump**. Predeploy passes (no mismatch). New code goes live.
2. Open Render Shell against the new web container, run:
   ```bash
   bin/rails "events:projections:rebuild[<name>]"
   ```
   This stamps `projection_versions` at the current (still-old) version. Live events between code-swap and rebuild-complete get projected by the new code; replay reapplies them idempotently. This is the one rebuild — and the one outage window — Path B costs.
3. **Promote the stamp** to the version PR 2 will declare, in the same shell:
   ```bash
   bin/rails "events:projections:mark_rebuilt[<name>,<new CODE_VERSION>]"
   ```
   The rebuilt state was produced by the handler code PR 2 ships, so it *is* that version's state; the stamp just says so before the constant catches up. Stamps only move forward, so a typo cannot regress one.
4. **PR 2**: bump `CODE_VERSION` to the promoted value. Predeploy's `verify` sees stamp == code and passes. Do **not** set `REBUILD_ON_DEPLOY` — with the stamp promoted, `rebuild_if_stale` would skip anyway, but leaving the variable off keeps the env group honest.

Skipping step 3 is safe but expensive: PR 2's predeploy would then find the stamp behind and run the whole rebuild again inside the deploy window — the second outage Path B exists to avoid.

### Path C — surgical single-tenant rebuild

For targeted fixes (data corruption on one tenant, framework-specific bug), use the two-arg form:

```bash
bin/rails "events:projections:rebuild[<name>,<tenant_id>]"
```

This does NOT stamp `projection_versions` — it's an operational fix, not a "production-grade rebuild for this version". A subsequent global rebuild stamps as normal.

### Path D — rebuild everything (bulk recovery)

For full recovery after a major event-store restore, a fresh environment seed, or a sweeping refactor that touches every projection:

```bash
bin/rails events:projections:rebuild_all
```

Under the hood this calls `Projections::GlobalReplayer.replay_all`: it truncates every projection's read models up front, then makes a **single pass** over the event store filtered by `of_type(<every handled event class>)`, dispatching each event to every interested projection in global insertion order. After all tenants are processed, it stamps `projection_versions` for every projection.

Why one pass beats N passes:

- Cross-projection causality is structural. `PersonEnrolled` (cycles) is applied before any PD event that depends on cycle state, because that's the order they were persisted live. No "rebuild dependency order" mental model required.
- Reads the event store once, not four times. At scale this is the dominant cost.
- Each read-model table has exactly one projection writer (see `docs/guidelines/event-sourcing.md`), so truncate-everything-up-front is structurally safe — no projection's reset cascades into another projection's tables.

When to prefer Path D over Path A:

- A schema-altering migration changed read-model tables across multiple projections.
- The event store was restored from a backup and you want to rebuild reads from scratch.
- You bumped `CODE_VERSION` on three or four projections in the same release and don't want to type each name.

When NOT to use Path D:

- Only one projection's logic changed. Use Path A (`REBUILD_ON_DEPLOY=<name>` for one name) — much cheaper, leaves the other three stamps untouched.
- Targeted single-tenant fix. Use Path C.

Path D is still a heavy operation. Production rules apply — fresh snapshot first, quiet window, monitoring on.

## Pre-flight checks

Before running any rebuild on production, in a Rails console on the target environment:

```ruby
# 1. Projection class loads and lists the events you expect
Frameworks::Projections::PublishedState.handled_events.size

# 2. Contract is implemented
Frameworks::Projections::PublishedState::PROJECTION_NAME
Frameworks::Projections::PublishedState::CODE_VERSION
Frameworks::Projections::PublishedState.respond_to?(:reset!)

# 3. Currently stamped version
ProjectionVersion.find_by(name: "frameworks/published_state")&.version

# 4. Estimate event volume for the projection's types
Rails.configuration.event_store
  .read
  .of_type(Frameworks::Projections::PublishedState.handled_events)
  .count

# 5. Event store integrity — sample one event, verify tenant_id metadata
sample = Rails.configuration.event_store.read.limit(1).first
sample&.metadata&.[](:tenant_id)
```

If steps 3 + 4 suggest the rebuild will take longer than predeploy allows, use Path B.

## Failure modes

| Symptom | Likely cause | Action |
|---|---|---|
| `KeyError: Unknown projection` from rake task | Projection not in `Projections::Registry::REPLAYABLE` | Add it (or check spelling) |
| `NoMethodError: undefined method 'reset!'` | Contract not implemented for this projection | Add `reset!` per [event-sourcing.md](../guidelines/event-sourcing.md) |
| Round-trip test fails after `reset!` change | `reset!` not truncating a table the projection writes; or write to a new column not yet covered | Audit owned read models; fix `reset!` or `snapshot_read_models` |
| Duplicate rows after replay | `reset!` didn't truncate everything; or two projections fighting over a shared row | Re-examine ownership; document in [event-sourcing.md](../guidelines/event-sourcing.md) |
| Replay runs forever | Very large stream history | Use Path B; consider chunking via `BatchEnumerator` |
| Read model wrong after replay | Event payload differs across history; old events have old shape | Add an RES upcaster, then rebuild |
| Live users see Turbo channel thrashing during rebuild | A side-effect handler (broadcast, ActionCable, job) missing `Projections::Replayer.replay_mode?` guard | Add the guard; redeploy before the next rebuild |
| Predeploy fails after deploy looked clean | Version bumped in code but `projection_versions` not stamped | Use Path A or B above; do NOT use `mark_rebuilt` without verifying state |
