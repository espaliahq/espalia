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
FREQUENCY = { "none" => 0.0, "some" => 1/3, "occasional" => 2/3, "consistent" => 1.0 }   # equal steps (ADR-24)
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
  Home-level floor (ADR-22): when a person is read against another role or
  level (a lens), the default is 1.0 only if o < the level being read AND
  o < home_level. Reading an E2 as EM4 must not assume L3 for free. When the
  lens is the home role the two levels are equal and nothing changes. The
  engine takes it as `home_level:` (default `person_level`); the builder
  passes the lens's home level and exposes the floor as `assumed_below`, which
  the level chips paint.

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
| flexible (resolved tolerance > 0) | `f(b, L)` — multiplicative | "most of the time" at L with "consistently" at L+1 earns two-thirds of the next-level credit |
| mandatory (resolved tolerance 0 — the "Required" badge) | `1 if f(b, L) ≥ 1.0 else 0` — step | nothing above the level counts until the level itself is consistent |

For a cap of 2 or more the factor chains along the levels (credit at L+2 is gated by L and by L+1).

Making up **across** capabilities stays allowed — that is what the weighted average is — bounded by the per-capability deficit threshold (blocking) and the category gates. The mandatory case is a step because with a multiplicative gate a mandatory capability at "most of the time" with "consistently" above nets to no deficit, is never blocked, and the one rule written for it is defeated.

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
deficit      = max(0, −contribution), counting rated cells only

Verdict gate: deficit > deficit_threshold → capability is :blocked
```

**Only a rating can block** ([#485](https://github.com/mr-yum/growth-os/issues/485)). An unrated cell the score counts as 0 — at or above the assessed level, where nothing is assumed — is left out of the deficit, so a capability nobody has rated is `:unrated`, never `:blocked`. Blocking used to fire on the 0 itself, so a fresh assessment showed Blocked beside "Not rated" on every card. The score is unchanged: the 0 still holds the number down, which the coverage gate and the "X of Y rated" chip already say. A "not yet" still blocks, and so does a rated gap below the assessed level while the assessed level waits on a rating.

An unrated capability still **holds** the verdict (see *Verdicts*): nothing has shown the level is met. It has to, or the rule would invert. With 23 capabilities consistent but one unrated the score is 96% and clears the meeting bar, while rating that one "not yet" blocks, so skipping the honest low rating would pass. It is reported apart from the blocked ones — `Scoring#unrated` — because "blocked" is a judgement and it has none. Nor is the hold a corner case: credit earned above the assessed level can lift the score past the bar while cells at the level are still unrated (the seeded data has someone at 104% with three unrated).

At the default 0.75 a current-level "not yet" (deficit 1.0) blocks; "some" and "most of the time" can be made up by strength elsewhere. At the previous default of 1.0 the gate could never fire — a capability's current-level deficit maxes out at exactly 1.0. Tolerance 0 marks the capability mandatory: any gap blocks, and the step gate applies.

The framework-wide value lives on `framework_states.deficit_threshold`; **nil means the system default** (like the three ratio thresholds), so the default lives in one constant and moves with the code. Migration `20260916000001` made the column nullable and set never-configured rows to nil, leaving any explicitly configured value — including 1.0 — exactly as its event says, so a projection rebuild reproduces the same state.

---

## Per-capability Status

| Status | Condition |
|--------|-----------|
| `:blocked` | rated deficit > effective_deficit_threshold — blocks meeting/mastery/promotion |
| `:unrated` | not blocked, but a cell the score counts as 0 has no rating yet — holds meeting/mastery/promotion without being a judgement |
| `:above_cap` | consistent at ordinals beyond reference_level + overperformance_cap |
| `:at_bar` | effective_freq at reference_level >= 1.0 (consistent) |
| `:developing` | below bar, not blocked |

---

## Verdicts

`level_verdict(reference_level)` is the single code path used by column chips, promotion readiness and the hero:

```
level_verdict(reference_level):
  score = performance_ratio_at_level(reference_level)
  held = any capability :blocked or :unrated at reference_level

  :mastering  if score >= mastery_threshold AND NOT held
  :meeting    if score >= meeting_expectation_threshold AND NOT held
  :below      otherwise

meeting_expectations? = performance_ratio >= meeting_expectation_threshold AND NOT held
mastering?            = performance_ratio >= mastery_threshold AND NOT held
agreed_level          = max(level_ordinal where effective_frequency == "consistent") — derived, never stored
```

---

## Performance State Machine

`Scoring#performance_state` returns a single symbol that drives the hero. The vocabulary is chosen so the hero always points at the **next milestone** — never one already cleared.

```ruby
:underperforming  score < underperforming_threshold (default 0.80)
                  → the milestone is the current level's bar
:progressing      underperforming_threshold ≤ score < meeting_threshold
                  OR any capability held (blocked, or unrated)
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

Precedence: **underperforming → progressing → top_of_ladder → eligible → mastering → performing**. Blocked-precedence means a single held capability downgrades an otherwise-passing person to `:progressing`.

### `has_next_level?` and `next_level_contribution(binding)`

```ruby
next_level_ordinal           → the next ordinal in the role's ladder above person_level (nil at the top)
has_next_level?              → next_level_ordinal present
next_level_contribution(b)   → raw_contribution_at_level(b, next_level_ordinal)
```

The builder exposes `capability_scores_at_next_level` when a next level exists; the hero's `:performing` and `:mastering` panels sort it ascending to name the real gap to the next level, and fall back to the assessed level — label included — when that level carries no expectations yet.

---

## Category Pass/Fail

A category passes when **its own score clears the meeting bar and none of its
capabilities is blocked** — the same verdict `category_state` carries, so the
section header's number and the pass/fail a report reads can't disagree:

```
pass = category_state(category_id) not in [:underperforming, :progressing]
     # i.e. category_components(id)[:score] >= meeting_expectation_threshold
     #      AND no member capability is held at person_level
pool = Σ raw_contribution per binding in category   # weight units, still exposed
```

The category's `deficit_threshold` keeps its **blocking** role — it is resolved
per capability (`binding → category → framework`), so a tighter category
tolerance still blocks a member and therefore still fails the category. What is
gone is the separate pool-in-points gate: a category used to be able to fail on
a weight-unit sum while its own score said it was meeting, which is the same
level-dependence ADR-21 removed everywhere else. `pool` is still returned for
callers that want the weight-unit net (`Reporting::CapabilityAttainment` reads
only `pass`).

---

## Promotion Readiness

Evaluated at the NEXT level with the same score formula — `level_verdict(next_level)`. Eligible when both:

1. Score: `performance_ratio_at_level(next_level) >= meeting_expectation_threshold`
2. Nothing held at the next level — no `:blocked` capability (`blocked_at_next_level`) and none unrated (`unrated_at_next_level`)

With the default cap of 1 that is "score ≥ 1.95 and nothing held at L+1" — the same bar at every level. The hero's promotion pill names both lists ("Blocked by 1 capability · 4 capabilities to rate at E4").

---

## Configuration UI

Framework-level scoring thresholds are configurable at `GET /frameworks/:id/settings` (admin-only) and over MCP (`frameworks_configure_scoring_thresholds`, `:in_app`). Each setting can be customised or reverted to the system default. Changes flow through the event-sourced pipeline:

`Frameworks::SettingsController#update` → `Operations::Frameworks::ConfigureScoringThresholds` → `CommandHandler#configure_scoring_thresholds` → `ScoringThresholdsConfigured` event → `PublishedState` projection → `framework_states` table.

Nil values in the nullable columns (`mastery_threshold`, `meeting_expectation_threshold`, `underperforming_threshold`, `deficit_threshold`) mean "use system default". The one NOT NULL column (`overperformance_cap`) is reset to its constant default when reverted.

**Ordering is validated.** The state machine walks underperforming → meeting → mastery in a fixed order, so the Operation refuses `underperforming < meeting < mastery` violations as a `ParameterError` (resolving omitted values to their defaults first), and the aggregate refuses inverted supplied values.

---

## UI Implications

### Hero summary

The number, a two-segment bar (0–100 the assessed level, 100–200 the next, labelled with the level codes; a single segment at the top of the ladder), a state-driven verdict, and a gloss naming the components. See [assessments/scoring.md](../guidelines/assessments/scoring.md#hero-summary--three-bands). Colour tiers read the framework's configured thresholds — never a hard-coded number.

### One scale at three altitudes

The same formula answers the assessment, one category and one capability —
`components_over(bindings, reference)` with a narrower set of bindings each
time (`components`, `category_components(category_id)`,
`capability_components(binding)`), and `state_for` applied to each. So a
card, its category header and the hero cannot disagree, and the reader
learns one number once.

What differs is only how much vocabulary each altitude can afford:

| Altitude | Shows | Deliberately omits |
|---|---|---|
| Hero | Number, `:lg` bar with tick-labelled level codes, the state as a verdict sentence, the components as a gloss | — |
| Category header | Rated count, the split when it adds anything, tone-coloured number, `:md` bar | The state **word** (a `title` only) — a scanned indicator has no room for it |
| Capability card | The split, tone-coloured number, `:sm` bar | The state word; the number alone stands in for it |

A fourth caller sits slightly apart: the hero's gap list scores each
capability at the level the panel *points at* rather than the one the person
stands on — `capability_scores_at(reference_level)`, the same components with
the same state vocabulary, plus the `scorable` flag a gap list needs to leave
out capabilities that owe nothing at that level.

Three shared rules, all in `Views::Assessments::Concerns::ScoreScale`:

- **Tone comes from the state, never the number** — a 150 held at
  `:progressing` by a blocked capability reads amber like its verdict.
- **Level codes are read off the role's own ladder** (`merged_levels`), the
  same list the engine scores against, so a gap in the ordinals can't make
  copy and number disagree.
- **A band the cap doesn't allow isn't drawn.** The bar's segment count is
  the engine's `bands_above`, clamped to the levels that actually exist.

Two honesty guards sit above the formula, both the hero's:

- **Unrated is not zero.** A capability with no rating at the assessed level
  reads "Not rated"; one with no expectation there reads "No expectation at
  E3". `capability_components` carries `scorable:` for the second case.
- **Coverage gates the category.** Below half the category's assessed-level
  cells rated, the header and the chip show no score at all.

### Where the binding facts show

| Signal | When | Display |
|--------|------|---------|
| Weight chip | `binding.weight != 1.0` | Muted `×2` chip on the assessment card's name row, the hero gap list and the explainer's "Counts differently" list ([#431](https://github.com/mr-yum/growth-os/issues/431)); `×2` marker in the calibration cohort drawer |
| Required chip | resolved `deficit_threshold == 0` (binding, then category, then framework default — the engine's `mandatory?`) | Muted "Required" chip on the same card row and explainer list, shown before any rating; the red "Blocked" badge is the later state once a rating shows a gap |
| Category threshold | `deficit_threshold` on a category | Not shown on any surface today; it reaches the reader only through the capabilities it makes Required |
| Agreed level | Derived | Shown as `"Agreed: L3"` computed from aligned assessments; no direct input |

The explorer's capability rows carry no weight badge today; weights are edited in the row kebab's "Edit roles…" binding editor.

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

---

## Checking a scoring change against production

Nothing persists a score, so a change to a weight, the gate or a default threshold rescores every assessment, closed cycles included, the moment it deploys. Before shipping one, measure it on production ratings.

1. **Pull the ratings read-only over the MCP server.** `assessments_capability_get` returns one capability's per-level self, manager and aligned ratings, its `weight`, whether it is `required`, and its prod score. `assessments_get` returns the overall and per-category scores. Each `capability_get` call is 7–20k tokens, because it carries every expectation and illustration, so a cohort means hundreds of calls: split them across subagents, each writing compact JSON to a scratch folder.
2. **Feed the extract into the real engine.** `PersonDevelopment::Scoring` is pure Ruby and takes duck-typed structs (`bin/rails runner`). Map `required: true` to a binding tolerance of 0, and pass every expectation level as an expectation cell.
3. **Reproduce prod before trusting the new numbers.** Run the current constants first and match every overall and category score exactly. The MCP serves an admin the `aligned_only` perspective once a cell is agreed and `manager_only` before, so score each perspective and use the one that matches. A miss means the extract or an assumption is wrong. For example, `capability_get` does not expose a binding's tolerance or cap override, so the defaults are assumed.
4. **Swap the constant and rescore.** Count the state flips at the 80, 95 and 150 lines, and for categories, which flip far more often because they hold only three or four capabilities.

ADR-24's equal-step weights were checked this way. The rescore found the verdict flips near 1.5; a second pass over one weighted capability found the blocks it lifts, which a sample of ×1 capabilities can't show. Check every binding weight other than 1 separately: the deficit scales with it.
