# Scoring Model — PersonDevelopment::Scoring

> Read this when: working on assessment scoring, capability matrix display, performance verdicts, promotion readiness, the heatmap, or the scoring panel UI.

Pure Ruby class (no ActiveRecord). Instantiated on demand from projection read models.

---

## Core Formulae

```
FREQUENCY = { "none" => 0.0, "some" => 0.25, "occasional" => 0.5, "consistent" => 1.0 }
DEFAULT_MASTERY_THRESHOLD = 1.15
DEFAULT_MEETING_EXPECTATION_THRESHOLD = 0.95
DEFAULT_OVERPERFORMANCE_CAP = 1
DEFAULT_DEFICIT_THRESHOLD = 1.0

effective_frequency(capability_stable_id, level_ordinal):
  aligned_frequency  → manager_rated_frequency  → self_rated_frequency
  → default: 1.0 if level_ordinal < person_level (assume consistent for past levels)
             0.0 if level_ordinal >= person_level (current level and above must be explicitly assessed)

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

Nil values in nullable columns (`mastery_threshold`, `meeting_expectation_threshold`) mean "use system default". NOT NULL columns (`overperformance_cap`, `deficit_threshold`) are reset to their constant defaults when reverted.

---

## UI Implications

### Capability Matrix Badges

| Signal | When | Display |
|--------|------|---------|
| Weight badge | `binding.weight != 1.0` | `"2×"` badge on capability row |
| Shared vs per-role weight | All selected roles have same weight | Unified badge; otherwise per-role coloured dots |
| Mandatory indicator | `deficit_threshold == 0` on binding | Filled/solid amber weight badge + 3px amber left border on row |
| Category threshold | `deficit_threshold == 0` on category | Lock icon on category section header |
| Category threshold | `deficit_threshold > 0` on category | `"± N pts"` label on section header |
| Category threshold | `nil` on category | No indicator (inherits framework default) |
| Frequency selector | Self/manager/align input | Three toggle buttons: `some` · `occasional` · `consistent`. Clicking the selected button clears the rating (untoggle). |
| Agreed level | Derived | Show as `"Agreed: L3"` computed from aligned assessments; no direct input |

### Assessment Cell Heatmap (background colour fills)

Cells get background tints based on their rating relative to expectations at that level. Explicit ratings are more saturated than defaults.

| Cell state | At/below person level | Above person level |
|------------|----------------------|-------------------|
| Unrated (default consistent) | Muted green tint | Neutral gray |
| Rated "consistent" | Solid green | Solid green (exceeding) |
| Rated "occasional" | Amber | Blue (stretch attempt) |
| Rated "some" | Red | Blue (stretch attempt) |

### Scoring Panel — Three-tier Performance Signal

| Tier | Condition | Display |
|------|-----------|---------|
| Below expectations | `performance_ratio < meeting_expectation_threshold` (default 0.95) OR any :blocked capabilities | Red warning — performance concern |
| Meeting expectations | `performance_ratio >= meeting_expectation_threshold` AND no :blocked capabilities | Green — at or above current level baseline |
| Mastering | `performance_ratio >= mastery_threshold` (default 1.15) AND no :blocked capabilities | Purple — significantly exceeding expectations |

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

The UI has three assessment contexts (`:self`, `:manager`, `:alignment`) that determine which perspective is primary. This mirrors the `AssessmentCell` pattern where `context:` determines which frequency is interactive.

| Context | Primary scoring | Secondary bars | Context label |
|---------|----------------|----------------|---------------|
| `:self` | `self_scoring` | Mgr, Agreed (if present) | "Self Assessment" |
| `:manager` | `manager_scoring` | Self, Agreed (if present) | "Manager Assessment" |
| `:alignment` | `aligned_scoring` | Self, Mgr | "Agreed Assessment" |

The primary scoring drives all panel sections: performance %, status tier, category results, and promotion readiness. Secondary perspectives appear as compact bars (matching `FrequencyBar` visual language) and divergence annotations.

### Divergence Display

Divergence between perspectives is surfaced at every level of the scoring panel:

| Section | Divergence indicator | Detail shown |
|---------|---------------------|--------------|
| Performance % | Compact bar per secondary perspective + amber dot when ≥5% apart | Exact percentage |
| Status tier | Amber dot + text annotation below primary badge | Alternate tier label ("Mgr: Meeting expectations") |
| Category results | Amber dot on row + inline text below | Alternate pass/fail ("Self: Below") |
| Promotion | Amber dot + text annotation | Alternate eligibility ("Self: Eligible") |

**Design rationale:** Divergence is shown explicitly (with alternate result text, not just a dot) because disagreements are conversation opportunities. In the alignment context, both original positions (self + manager) are shown to make the starting points visible alongside the agreed result.

### Visual Language Consistency

The scoring panel's secondary display mirrors the cell-level `FrequencyBar` pattern:
- Compact horizontal bar with label, colored strip, and value
- Amber divergence dot (1.5px) when perspectives disagree
- Same color tiers (purple/green/amber/red) across cells and panel

This ensures a user scanning from the matrix cells to the scoring sidebar sees a consistent visual language at every granularity.
