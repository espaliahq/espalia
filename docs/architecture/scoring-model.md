# Scoring Model — PersonDevelopment::Scoring

> Read this when: working on assessment scoring, capability matrix display, performance verdicts, promotion readiness, the heatmap, or the scoring panel UI.

Pure Ruby class (no ActiveRecord). Instantiated on demand from projection read models.

---

## Core Formulae

```
FREQUENCY = { "none" => 0.0, "some" => 0.25, "occasional" => 0.5, "consistent" => 1.0 }
DEFAULT_MASTERY_THRESHOLD = 1.15
DEFAULT_MEETING_EXPECTATION_THRESHOLD = 0.95
DEFAULT_UNDERPERFORMING_THRESHOLD = 0.80
DEFAULT_OVERPERFORMANCE_CAP = 1
DEFAULT_DEFICIT_THRESHOLD = 1.0

effective_frequency(capability_stable_id, level_ordinal):
  aligned_frequency  → manager_rated_frequency  → self_rated_frequency
  → default: 1.0 if level_ordinal < person_level (assume consistent for past levels)
             0.0 if level_ordinal >= person_level (current level and above must be explicitly assessed)
  note: person_level is the cycle's ASSESSED level (the enrollment snapshot
        resolved by Assessments::MatrixDataBuilder), NOT the person's live
        assignment level — so a promotion never silently re-scores a completed
        cycle. See ADR-19.

contribution_at_level = (effective_frequency − expected_at_level) × weight
  where expected_at_level = level_ordinal <= person_level ? 1.0 : 0.0

raw_contribution(capability) = Σ contribution_at_level across ALL level ordinals

baseline_score = Σ (count_levels_at_or_below_person_level × weight) per binding

performance_ratio = (raw_score + baseline_score) / baseline_score
  → 1.0 = exactly at expectations; > 1.0 = exceeding; < 1.0 = below
```

---

## Over-performance Cap

Resolved per capability: `binding.overperformance_cap || category.overperformance_cap || framework.overperformance_cap` (default 1).

Ordinals beyond `reference_level + cap` contribute 0 to the score.

---

## Deficit Threshold

Resolved per capability: `binding.deficit_threshold || category.deficit_threshold || framework.deficit_threshold` (default 1.0).

```
contribution = Σ (effective_frequency − expected_at_level) × weight
               across all ordinals ≤ reference_level + overperformance_cap
deficit = max(0, −contribution)

Verdict gate: deficit > deficit_threshold → capability is :blocked
```

Over-performance at higher levels can offset gaps at the reference level, subject to `overperformance_cap`. With the default cap of 1, a person rated "consistent" one level above their assigned level contributes positively and reduces the deficit. Setting `overperformance_cap` to 0 disables any above-level offset — only ordinals at or below the reference level count.

---

## Per-capability Status

| Status | Condition |
|--------|-----------|
| `:blocked` | deficit > effective_deficit_threshold — blocks meeting/mastery/promotion |
| `:above_cap` | consistent at ordinals beyond reference_level + overperformance_cap |
| `:at_bar` | effective_freq at reference_level >= 1.0 (consistent) |
| `:developing` | below bar, not blocked |

---

## Three Symmetric Verdicts

All verdicts combine a score ratio check with a blocking gate. The `level_verdict(reference_level)` method is the single code path used by column headers, promotion readiness, and the sidebar status — ensuring consistency across the UI.

```
level_verdict(reference_level):
  ratio = performance_ratio_at_level(reference_level)
  has_blocked = any capability :blocked at reference_level

  :mastering  if ratio >= mastery_threshold AND NOT has_blocked
  :meeting    if ratio >= meeting_expectation_threshold AND NOT has_blocked
  :below      otherwise

meeting_expectations? = performance_ratio >= meeting_expectation_threshold AND NOT has_blocked
  → Uses performance_ratio (effective_frequency defaults unrated below person_level to 1.0)
  → NOT the same as level_verdict — level_verdict uses performance_ratio_at_level which
    treats unrated at/above person_level as 0.0 via explicit_frequency
  → meeting_expectation_threshold defaults to 0.95 (95% of expectations)
  → Frameworks can override via meeting_expectation_threshold on framework_states

mastering? = performance_ratio >= mastery_threshold AND NOT has_blocked
  → Same scoring path as meeting_expectations?, different threshold
  → Defaults to 1.15 (15% above expectations). Always returns boolean.
  → Frameworks can override via mastery_threshold on framework_states

agreed_level = max(level_ordinal where effective_frequency == "consistent")
  ← derived, never stored
```

---

## Performance State Machine

`Scoring#performance_state` returns a single symbol that drives the hero summary's narrative panel. The vocabulary is chosen so the UI always points at the **next milestone** — never one already cleared.

```ruby
:underperforming  performance_ratio < underperforming_threshold (default 0.80)
                  → next milestone is the current-level meeting bar
:progressing      underperforming_threshold ≤ ratio < meeting_threshold
                  OR any capability blocked
                  → next milestone is still the current-level meeting bar;
                    a blocked capability also lands here regardless of ratio
:eligible         has_next_level AND promotion_readiness[:eligible]
                  → past the last gate, celebrate
:mastering        ratio ≥ mastery_threshold AND NOT eligible
                  → next milestone is promotion to E(n+1)
:performing       fallback (meeting_threshold ≤ ratio < mastery_threshold)
                  → next milestone is mastering the current level
```

Precedence: **underperforming → progressing → eligible → mastering → performing**. Eligible-precedence-over-mastering means promotion-readiness is the louder signal once both fire. Blocked-precedence-over-performing means a single blocker downgrades an otherwise-passing person to `:progressing` — same rule as `meeting_expectations?`.

The state machine intentionally has no separate "progressing toward next level" state. At 110% performance ratio, a previous design fired `:progressing_to_next` because next-level ratio was above the underperforming floor — but that's misleading UX. The person hasn't mastered current yet; pointing at promotion skips a step. The simpler model: `:performing` owns 0.95–1.15, framed as "Gap to mastering". See [assessments.md](../guidelines/assessments.md#middle-band--state-driven) for the hero panel that consumes this.

### `has_next_level?` and `next_level_contribution(binding)`

Two public helpers on Scoring exist for the hero's gap-to panels:

```ruby
has_next_level?              → person_level < all_level_ordinals.last
next_level_contribution(b)   → raw_contribution_at_level(b, person_level + 1)
```

The matrix data builder uses these to expose `capability_contributions_at_next_level` on each scoring perspective when there IS a next level. The hero's `:performing` panel ("Gap to mastering") and `:mastering` panel ("Gap to promotion") both consume this dict — they sort ascending and surface the lowest-contributing capabilities as the actual gap.

`:performing` switched to this data source because the previous current-level-contribution version showed `+0.0` for capabilities meeting expectations exactly — those aren't gaps, they're meeting. The real gap to mastering lives at L+1: mastery requires overperformance, which means consistent at L+1.

---

## Category Pass/Fail

```
category_pool = Σ raw_contribution per binding in category
category_threshold = category.deficit_threshold || framework.deficit_threshold (default 1.0)
has_blocked = any capability in category is :blocked at person_level
pass if category_pool >= -category_threshold AND NOT has_blocked

Contributions are NOT individually capped — a single underperforming capability
can drag the pool negative, but strong peers can offset it. However, a blocked
capability always fails the category regardless of pool balance.
```

---

## Promotion Readiness

Evaluated at NEXT level using `level_verdict(next_level)` — same code path as column headers and sidebar verdicts. Contributions are recomputed as if `person_level` were `next_level`. This means the next level's ordinal is expected (1.0), not bonus (0.0). You must demonstrate capability at the next level to be promotion-ready.

Eligible when `level_verdict(next_level) != :below`, which requires both:
1. Score: `performance_ratio_at_level(next_level) >= meeting_expectation_threshold`
2. No `:blocked` capabilities at next level (deficit > deficit_threshold blocks)

Frameworks can override via `meeting_expectation_threshold` on framework_states.

---

## Configuration UI

Framework-level scoring thresholds are configurable via the settings page at `GET /frameworks/:id/settings` (admin-only). Each setting can be customised or reverted to the system default. Changes flow through the event-sourced pipeline:

`Frameworks::SettingsController#update` → `CommandHandler#configure_scoring_thresholds` → `ScoringThresholdsConfigured` event → `PublishedState` projection → `framework_states` table.

Nil values in nullable columns (`mastery_threshold`, `meeting_expectation_threshold`, `underperforming_threshold`) mean "use system default". NOT NULL columns (`overperformance_cap`, `deficit_threshold`) are reset to their constant defaults when reverted.

The `underperforming_threshold` is a 2026-05 addition powering the `:underperforming` / `:progressing` boundary in the performance state machine. Past `ScoringThresholdsConfigured` events don't carry the field, so the projection's writes are identical to before — the new column stays NULL on legacy frameworks and `Scoring` falls back to `DEFAULT_UNDERPERFORMING_THRESHOLD` (0.80). No projection rebuild needed.

---

## UI Implications

### Framework explorer — capability matrix badges

These apply to the framework explorer's read-only matrix view. The assessment view uses capability cards with a level strip; see [assessments.md](../guidelines/assessments.md#capability-cards) for the card / chip equivalents.

| Signal | When | Display |
|--------|------|---------|
| Weight badge | `binding.weight != 1.0` | `"2×"` badge on capability row |
| Shared vs per-role weight | All selected roles have same weight | Unified badge; otherwise per-role coloured dots |
| Mandatory indicator | `deficit_threshold == 0` on binding | Filled/solid amber weight badge + 3px amber left border on row |
| Category threshold | `deficit_threshold == 0` on category | Lock icon on category section header |
| Category threshold | `deficit_threshold > 0` on category | `"± N pts"` label on section header |
| Category threshold | `nil` on category | No indicator (inherits framework default) |
| Agreed level | Derived | Shown as `"Agreed: L3"` computed from aligned assessments; no direct input |

### Rating input — four-button FrequencySelector

The assessment view rates through the inline `FrequencyPill` (popover options `Not yet` / `Some of the time` / `Most of the time` / `Consistently`; the legacy four-button `FrequencySelector` carries the same labels). Clicking the currently-selected button clears the rating (untoggle). The selector is replaced with a read-only `FrequencyBar` when `frozen` (cycle in `aligning` / `aligned`) or `alignment_locked` (cycle `aligned`).

### LevelChip heatmap

`LevelChip` background tints are keyed by frequency × level position. See [assessments.md](../guidelines/assessments.md#level-chip-coloring) for the full table — same color rules the matrix cells used in the previous design.

### Hero summary — Five-state performance panel

The legacy three-tier sidebar is replaced by `HeroSummary` in the unified sticky header. Its middle band is a single state-driven panel keyed off `performance_state`. Each state picks the tone, headline, and which 3 capabilities to surface as evidence — see [assessments.md](../guidelines/assessments.md#middle-band--state-driven) for the full UI table.

| State | Tone | Headline | Capability list framing |
|---|---|---|---|
| `:underperforming` | red | "Underperforming at E(n)" | 3 lowest current-level contributions |
| `:progressing` | amber | "Progressing toward E(n)" | 3 lowest current-level contributions |
| `:performing` | blue | "Performing at E(n)" | 3 lowest **next-level** contributions (gap to mastering) |
| `:mastering` | purple | "Mastering E(n)" | blocked-at-next-level OR 3 lowest next-level contributions (gap to promotion) |
| `:eligible` | green | "Eligible for promotion to E(n+1)" | 3 highest current-level contributions |

Capability cards render the signed contribution delta (`+0.5` / `-0.5` / `+0.0`) directly — see the assessment guideline for color tiers.

---

## Multi-Perspective Scoring

### Perspective Parameter

The scoring engine accepts a `perspective:` parameter that controls which frequency field is used:

| Perspective | Frequency used | Purpose |
|-------------|---------------|---------|
| `:effective` (default) | Fallback chain: aligned → manager → self | Official composite score |
| `:self_only` | `self_rated_frequency` only | What the person's self-ratings alone produce |
| `:manager_only` | `manager_rated_frequency` only | What the manager's ratings alone produce |
| `:aligned_only` | `aligned_frequency` only | What the agreed ratings alone produce |

All other scoring logic (contribution, deficit, blocking, verdicts) is identical across perspectives — only the frequency source changes. This means perspective-specific scores are directly comparable.

`MatrixDataBuilder` computes four scoring hashes in parallel: `scoring` (effective), `self_scoring`, `manager_scoring`, and `aligned_scoring`. Perspective-specific hashes are nil when no ratings exist for that perspective (e.g. `manager_scoring` is nil until the manager rates at least one cell).

### Assessment Context and Primary/Secondary Display

The UI has three assessment contexts (`:self`, `:manager`, `:alignment`) that determine which perspective is primary.

| Context | Primary scoring | Subject pronoun in hero copy |
|---|---|---|
| `:self` | `self_scoring` | "You're …" |
| `:manager` | `manager_scoring` | "Alex is …" (first name of assessee) |
| `:alignment` | `aligned_scoring` | "Alex is …" |

`HeroSummary` uses the primary scoring's `performance_state`, `performance_ratio`, `promotion_readiness`, and `capability_contributions` to render the verdict + middle band + bottom-line. Secondary perspectives surface as small divergence dots on `LevelChip`s — see [assessments.md — Level chip coloring](../guidelines/assessments.md#level-chip-coloring). The full per-perspective `FrequencyBar`s live inside `CapabilityCardExpansion`, where the user has space for the comparison.

In `:self` context the data layer scrubs manager + aligned fields entirely before any view sees them; see [assessments.md — Self-assessment privacy](../guidelines/assessments.md#self-assessment-privacy).

### Divergence — chip dots + expansion bars

Divergence between perspectives appears at two levels:

| Surface | Indicator | Detail shown |
|---|---|---|
| `LevelChip` (in the level strip) | 2px amber dot when primary ≠ any secondary | None — dot is the only signal at strip level |
| `CapabilityCardExpansion` | One `FrequencyBar` per secondary perspective | Label (`Self` / `Mgr` / `Agreed`) + colored strip + value |

**Design rationale:** Divergence is shown by an explicit secondary value (not just an "X ≠ Y" indicator) because disagreements are conversation opportunities. In the alignment context, both original positions (self + manager) are shown alongside the aligned value so the starting points stay visible.
