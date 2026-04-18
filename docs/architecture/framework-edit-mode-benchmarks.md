# Framework Edit Mode — Replay Benchmarks

Measurement of the "in-memory replay per page load" approach (option A) under
consideration for the Framework Explorer edit mode. Goal: quantify whether we
can serve `/frameworks/:id/edit` by loading the aggregate fresh from the event
stream on each request, without a persistent draft read model.

## Setup

- Devcontainer Postgres on aarch64 Linux (local ORB-stack container)
- Ruby 4.0.1, Rails 8, RailsEventStore
- Measurement: `Process.clock_gettime(CLOCK_MONOTONIC)` around the relevant
  operation
- Frameworks: one real (the seeded me&u framework) plus two synthetic ones
  built via `bin/rails bench:fatten_framework SIZE=medium|large`
- Pass 2 iterations: 25, with 3 warmup runs ignored

All numbers are from a single-user local container. Production latency will
include network, serialization, and connection-pool contention; the curve is
the signal, not the absolute values.

## Results

### Pass 1 — projection rebuild (includes AR writes)

Measured inside `PublishedState#rebuild_framework_projection`, which fires
once per publish. Upper bound on "replay" cost because it also writes every
child read model. Instrumentation was **temporary** and has been reverted
([published_state.rb:188-206](../../app/contexts/frameworks/projections/published_state.rb#L188-L206)).

| Size   | Events | Rebuild elapsed | Per-event cost |
|--------|-------:|----------------:|---------------:|
| Small  | 1,627  |      6,799 ms   |    ~4.2 ms/ev  |
| Medium | 6,520  |     19,054 ms   |    ~2.9 ms/ev  |
| Large  | 15,788 |     46,454 ms   |    ~2.9 ms/ev  |

Dominated by AR writes — the projection destroys and rebuilds every child
table. Not representative of what edit mode would pay (no AR writes).

### Pass 2 — aggregate load only (pure L1)

`Frameworks::Repository.with_framework(fid) { |a| a }` — RES stream read +
`AggregateRoot` apply dispatch + hash mutations. No AR reads/writes. This is
the honest baseline for option A's hot-path cost per page load.

| Size   | Events | p50    | p95    | max    | mean   | Throughput      |
|--------|-------:|-------:|-------:|-------:|-------:|-----------------|
| Small  | 1,627  |  191 ms|  242 ms|  244 ms|  197 ms|  8.5 events/ms  |
| Medium | 6,520  |  499 ms|  642 ms|  674 ms|  515 ms| 13.1 events/ms  |
| Large  | 15,788 |1,230 ms|1,495 ms|1,528 ms|1,255 ms| 12.8 events/ms  |

Scaling is linear past a small fixed overhead (~20–30 ms per call). Steady-
state per-event cost ≈ 76 µs. No Pass 3 was run — Pass 2 alone is sufficient
to make the decision (see below).

## Interpretation

1. **Option A is clearly infeasible at medium+ without caching.** A 500 ms p50
   on the Medium profile (~6.5k events, ~120 capabilities, ~16 roles — a
   realistic mid-size enterprise framework) is felt as sluggish on every
   edit-mode page load. Large (~300 capabilities, 1.2 s p50 / 1.5 s p95) is
   unacceptable for interactive UI.
2. **The Small framework lives just at the edge.** At 191 ms p50 / 242 ms p95
   for the seeded framework (~40 capabilities), even the smallest realistic
   customer already pays a noticeable latency penalty per request.
3. **Two frames per navigation makes it worse.** The explorer fetches the
   shell and the matrix Turbo Frame — edit mode would replay the aggregate
   twice per navigation unless memoized.
4. **L1 alone is only half the story.** Pass 3 (the `DraftGraphBuilder` that
   would convert the aggregate's flat hashes into a `MatrixDataBuilder`-
   compatible graph) was not built, because the L1 numbers already rule out
   the uncached path. L1+L2 can only be slower than L1.

## Decision

**Reject option A as a standalone strategy.** The clean in-memory-replay path
is too slow for realistic framework sizes. Two viable paths remain:

- **A′ — replay + aggressive caching.** Cache the loaded aggregate (or the
  materialized draft graph) in SolidCache, keyed by framework_id and the last
  event position. Invalidate on any new event in the stream. First edit-mode
  request on a framework is slow, subsequent ones within the cache window are
  ~free. Complexity: one cache layer, a keep-in-sync subscriber.
- **B — polymorphic parallel draft projection.** Persistent draft tables
  mirroring published ones, fed by the same projection code parameterised on
  a `ModelSet`. Complexity: ~8 new tables, migration lifecycle, editorial
  event fan-out to both table families during a draft. Once built, reads are
  native-AR fast.

Given the size curve, **A′ is the likely winner for MVP**: it preserves "no
new schema", keeps the aggregate as the single source of truth, and trades
one-time latency for cache complexity rather than schema complexity. B
remains the right upgrade path if edit mode grows features that need rich
reads (search, activity feed, admin lists).

## Reproducing

```bash
# Small — stock seed
bin/rails db:reset
bin/rails bench:framework_replay

# Medium / Large — synthetic
SIZE=medium bin/rails bench:fatten_framework
FRAMEWORK_ID=<printed-uuid> bin/rails bench:framework_replay
```

The bench task lives at [lib/tasks/bench.rake](../../lib/tasks/bench.rake). It
is a one-shot diagnostic, not a CI test. Synthetic frameworks persist in the
dev database until `db:reset` — remove manually via `db:reset` or a
targeted delete if they clutter dev work.
