# Scoring Model — PersonDevelopment::Scoring

> Read this when: working on assessment scoring, capability matrix display, performance verdicts, promotion readiness, the calibration cohort view, or the hero summary.

Pure Ruby class (no ActiveRecord). Instantiated on demand from projection read models. The design record is [ADR-21](adrs.md); the user-facing framing lives in [assessments.md](../guidelines/assessments.md).

---

## The scale

One level-independent scale, read the same way at every level of every role:

| Score | Meaning |
|---|---|
| **1.00** | Meeting the assessed level — every bound capability consistent there (weighted) |
| **1.50** | Halfway to the next level |
| **2.00** | Demonstrating the next level in full — promotion ready |

Below 1.0 the number is the share of the assessed level demonstrated. The hero renders it as a percentage on a two-segment bar (0–100 the assessed level, 100–200 the next).

---

## Core Formulae

```
FREQUENCY = { "none" => 0.0, "some" => 0.25, "occasional" => 0.5, "consistent" => 1.0 }
DEFAULT_MASTERY_THRESHOLD             = 1.50   # halfway to the next level
DEFAULT_MEETING_EXPECTATION_THRESHOLD = 0.95
DEFAULT_UNDERPERFORMING_THRESHOLD     = 0.80
DEFAULT_OVERPERFORMANCE_CAP           = 1
DEFAULT_DEFICIT_THRESHOLD             = 0.75   # a current-level "not yet" blocks

f(b, o) = effective frequency of capability b at level o
  aligned_frequency → manager_rated_frequency → self_rated_frequency
  → default: 1.0 if o < person_level (assume consistent for past levels)
             0.0 if o >= person_level (the assessed level and above must be rated)
  person_level is the cycle's ASSESSED level (the enrollment snapshot), not
  the person's live assignment level — see ADR-19.

band(o) = Σ weight over bindings that carry a behavioural expectation at level o

prior   = Σ_{o < L} Σ_b weight·f(b,o) / Σ_{o < L} band(o)     (1.0 when no prior levels)
current = Σ_b weight·f(b,L) / band(L)
next    = Σ_{k ≤ cap} Σ_b weight·gate(b,k)·f(b,L+k) / band(L+k)

score   = max(0, current + next + (prior − 1))
```

Three things the arithmetic is built around:

- **Bands are normalised over the cells that carry an expectation.** A capability with no expectation at L+1 neither earns nor owes next-level credit. Every engine construction passes the cell set (`expectation_cells:`); the assessment builder derives it from the cells the matrix renders, the reporting and calibration queries from `BehaviouralExpectation`.
- **Prior levels pool into one bucket.** Their attainment is averaged into a bucket the size of a single band, so a deficit rated below the assessed level subtracts its share of that bucket — one "not yet" at L2 costs 1/(N × prior levels) of the score, a smaller share the more prior levels there are. Deliberate: the bucket is the same size at every level, which is what keeps the ceiling and the meeting bar level-independent, whereas the old ratio let every prior level pad the denominator (an L7 ceiling of 114%, a promotion gate needing 65% of the next band at L7 versus 95% at L1).
- **Weight is the unit everywhere.** A 2× capability is 2/band of every level it has an expectation at.

`performance_ratio` is `performance_ratio_at_level(person_level)` — one formula, so the hero and promotion readiness cannot disagree. "The next level" is the next ordinal in the role's ladder (`next_level_ordinal`), not `person_level + 1`, so a gap in the ordinals scores correctly; a level at which a capability has no expectation neither earns, owes, nor gates. `components` exposes `{ prior:, current:, next:, score: }` for the hero copy ("94% of E3 demonstrated · 38% of the way to E4 · 5% missing below E3").

---

## The progression gate

Credit above the assessed level is discounted **per capability** by how consistently that same capability is shown at the assessed level, so a capability cannot make up a gap at its own level with a rating above it:

| Binding | Gate | Effect |
|---|---|---|
| flexible (resolved tolerance > 0) | `f(b, L)` — multiplicative | "most of the time" at L with "consistently" at L+1 earns half the next-level credit |
| mandatory (resolved tolerance 0 — the "Required" badge) | `1 if f(b, L) ≥ 1.0 else 0` — step | nothing above the level counts until the level itself is consistent |

For a cap of 2 or more the factor chains along the levels (credit at L+2 is gated by L and by L+1).

Making up **across** capabilities stays allowed — that is what the weighted average is — bounded by the per-capability deficit threshold (blocking) and the category gates. The mandatory case is a step because with a multiplicative gate a mandatory capability at "most of the time" with "consistently" above nets to zero, is never blocked, and the one rule written for it is defeated.

---

## Over-performance Cap

Resolved per capability: `binding.overperformance_cap || category.overperformance_cap || framework.overperformance_cap` (default 1).

A window of levels: ordinals beyond `reference_level + cap` contribute 0. Because gated credit is monotone along the chain, the window is also the most a capability can earn — cap 1 → a 2.0 ceiling, cap 2 → 3.0, cap 0 → 1.0. A capability's share of a band is structural (it has an expectation there); a binding capped below the framework's cap holds its share at 0.

---

## Deficit Threshold (blocking)

Resolved per capability: `binding.deficit_threshold || category.deficit_threshold || framework.deficit_threshold` (default 0.75).

```
contribution = Σ (f − expected) × weight across capped ordinals,
               with above-level credit gated as above
deficit      = max(0, −contribution)

Verdict gate: deficit > deficit_threshold → capability is :blocked
```

At the default 0.75 a current-level "not yet" (deficit 1.0) blocks; "some" and "most of the time" can be made up by strength elsewhere. At the previous default of 1.0 the gate could never fire — a capability's current-level deficit maxes out at exactly 1.0. Tolerance 0 marks the capability mandatory: any gap blocks, and the step gate applies.

The framework-wide value lives on `framework_states.deficit_threshold`; **nil means the system default** (like the three ratio thresholds), so the default lives in one constant and moves with the code. Migration `20260916000001` made the column nullable and set never-configured rows to nil, leaving any explicitly configured value — including 1.0 — exactly as its event says, so a projection rebuild reproduces the same state.

---

## Per-capability Status

| Status | Condition |
|--------|-----------|
| `:blocked` | deficit > effective_deficit_threshold — blocks meeting/mastery/promotion |
| `:above_cap` | consistent at ordinals beyond reference_level + overperformance_cap |
| `:at_bar` | effective_freq at reference_level >= 1.0 (consistent) |
| `:developing` | below bar, not blocked |

---

## Verdicts

`level_verdict(reference_level)` is the single code path used by column chips, promotion readiness and the hero:

```
level_verdict(reference_level):
  score = performance_ratio_at_level(reference_level)
  has_blocked = any capability :blocked at reference_level

  :mastering  if score >= mastery_threshold AND NOT has_blocked
  :meeting    if score >= meeting_expectation_threshold AND NOT has_blocked
  :below      otherwise

meeting_expectations? = performance_ratio >= meeting_expectation_threshold AND NOT has_blocked
mastering?            = performance_ratio >= mastery_threshold AND NOT has_blocked
agreed_level          = max(level_ordinal where effective_frequency == "consistent") — derived, never stored
```

---

## Performance State Machine

`Scoring#performance_state` returns a single symbol that drives the hero. The vocabulary is chosen so the hero always points at the **next milestone** — never one already cleared.

```ruby
:underperforming  score < underperforming_threshold (default 0.80)
                  → the milestone is the current level's bar
:progressing      underperforming_threshold ≤ score < meeting_threshold
                  OR any capability blocked
                  → still the current level's bar
:top_of_ladder    meeting, and the role has no level above this one
                  → there is no next band to progress into
:eligible         meets the next level's expectations (promotion ready)
                  → past the last gate, celebrate
:mastering        score ≥ mastery_threshold (1.50) AND not eligible
                  → more than halfway; the milestone is promotion
:performing       fallback (meeting ≤ score < mastery)
                  → the milestone is progress toward the next level
```

Precedence: **underperforming → progressing → top_of_ladder → eligible → mastering → performing**. Blocked-precedence means a single blocker downgrades an otherwise-passing person to `:progressing`.

### `has_next_level?` and `next_level_contribution(binding)`

```ruby
has_next_level?              → any level ordinal above person_level
next_level_contribution(b)   → raw_contribution_at_level(b, person_level + 1)
```

The builder exposes `capability_contributions_at_next_level` when a next level exists; the hero's `:performing` and `:mastering` panels sort it ascending to name the real gap to the next level.

---

## Category Pass/Fail

```
category_pool = Σ raw_contribution per binding in category (weight units, gated)
category_threshold = category.deficit_threshold || framework.deficit_threshold
has_blocked = any capability in category is :blocked at person_level
pass if category_pool >= -category_threshold AND NOT has_blocked
```

---

## Promotion Readiness

Evaluated at the NEXT level with the same score formula — `level_verdict(next_level)`. Eligible when both:

1. Score: `performance_ratio_at_level(next_level) >= meeting_expectation_threshold`
2. No `:blocked` capabilities at the next level

With the default cap of 1 that is "score ≥ 1.95 and nothing blocked at L+1" — the same bar at every level.

---

## Configuration UI

Framework-level scoring thresholds are configurable at `GET /frameworks/:id/settings` (admin-only) and over MCP (`frameworks_configure_scoring_thresholds`, `:in_app`). Each setting can be customised or reverted to the system default. Changes flow through the event-sourced pipeline:

`Frameworks::SettingsController#update` → `Operations::Frameworks::ConfigureScoringThresholds` → `CommandHandler#configure_scoring_thresholds` → `ScoringThresholdsConfigured` event → `PublishedState` projection → `framework_states` table.

Nil values in nullable columns (`mastery_threshold`, `meeting_expectation_threshold`, `underperforming_threshold`) mean "use system default". NOT NULL columns (`overperformance_cap`, `deficit_threshold`) are reset to their constant defaults when reverted.

**Ordering is validated.** The state machine walks underperforming → meeting → mastery in a fixed order, so the Operation refuses `underperforming < meeting < mastery` violations as a `ParameterError` (resolving omitted values to their defaults first), and the aggregate refuses inverted supplied values.

---

## UI Implications

### Hero summary

The number, a two-segment bar (0–100 the assessed level, 100–200 the next, labelled with the level codes; a single segment at the top of the ladder), a state-driven verdict, and a gloss naming the components. See [assessments.md](../guidelines/assessments.md#hero-summary--three-bands). Colour tiers read the framework's configured thresholds — never a hard-coded number.

### Framework explorer — capability matrix badges

| Signal | When | Display |
|--------|------|---------|
| Weight badge | `binding.weight != 1.0` | `"2×"` badge on capability row |
| Shared vs per-role weight | All selected roles have same weight | Unified badge; otherwise per-role coloured dots |
| Required indicator | `deficit_threshold == 0` on binding | Filled/solid amber weight badge + 3px amber left border on row |
| Category threshold | `deficit_threshold == 0` on category | Lock icon on category section header |
| Category threshold | `deficit_threshold > 0` on category | `"± N pts"` label on section header |
| Agreed level | Derived | Shown as `"Agreed: L3"` computed from aligned assessments; no direct input |

### Rating input — the inline FrequencyPill

The assessment view rates through the inline `FrequencyPill`: a popover with the four options `Not yet` / `Some of the time` / `Most of the time` / `Consistently` plus an explicit "Clear rating" item. See [assessments.md](../guidelines/assessments.md).

### Calibration cohort view

Plots each person's `% of expected` (manager ratings only) on a 0–200 axis with reference lines at 100 ("meets expectations") and 200 ("next level"). The glossary entry defines both marks.

---

## Multi-Perspective Scoring

### Perspective Parameter

| Perspective | Frequency used | Purpose |
|-------------|---------------|---------|
| `:effective` (default) | Fallback chain: aligned → manager → self | Official composite score |
| `:self_only` | `self_rated_frequency` only | What the person's self-ratings alone produce |
| `:manager_only` | `manager_rated_frequency` only | What the manager's ratings alone produce |
| `:aligned_only` | `aligned_frequency` only | What the agreed ratings alone produce |

All other scoring logic (components, gate, deficit, blocking, verdicts) is identical across perspectives — only the frequency source changes, so perspective-specific scores are directly comparable.

`MatrixDataBuilder` computes four scoring hashes in parallel: `scoring` (effective), `self_scoring`, `manager_scoring`, and `aligned_scoring`. Perspective-specific hashes are nil when no ratings exist for that perspective.

### Assessment Context and Primary/Secondary Display

| Context | Primary scoring | Subject pronoun in hero copy |
|---|---|---|
| `:self` | `self_scoring` | "You're …" |
| `:manager` | `manager_scoring` | "Alex is …" (first name of assessee) |
| `:alignment` | `aligned_scoring` | "Alex is …" |

In `:self` context the data layer scrubs manager + aligned fields entirely before any view sees them; see [assessments.md — Self-assessment privacy](../guidelines/assessments.md#self-assessment-privacy).
