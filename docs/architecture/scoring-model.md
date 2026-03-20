# Scoring Model — PersonDevelopment::Scoring

> Read this when: working on assessment scoring, capability matrix display, performance verdicts, promotion readiness, the heatmap, or the scoring panel UI.

Pure Ruby class (no ActiveRecord). Instantiated on demand from projection read models.

---

## Core Formulae

```
FREQUENCY = { "none" => 0.0, "some" => 0.25, "occasional" => 0.5, "consistent" => 1.0 }
DEFAULT_MASTERY_THRESHOLD = 1.25
DEFAULT_PROMOTION_SCORE_THRESHOLD = 0.9

effective_frequency(capability_stable_id, level_ordinal):
  aligned_frequency  → manager_rated_frequency  → self_rated_frequency
  → default: 1.0 if level_ordinal <= person_level (assume consistent)
             0.0 if level_ordinal >  person_level (not expected, not assessed)

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
deficit = max(0, 1.0 - effective_freq_at_reference_level) * weight

Two roles:
  1. Category pool cap: capped_contribution = max(raw_contribution, -deficit_threshold)
  2. Verdict gate: deficit > deficit_threshold → capability is :blocked
```

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

meeting_expectations? = level_verdict(person_level) != :below
  → meeting_expectation_threshold defaults to 0.9 (90% of expectations)
  → Frameworks can override via meeting_expectation_threshold on framework_states

mastering? = level_verdict(person_level) == :mastering
  → Defaults to 1.25 (25% above expectations). Always returns boolean.
  → Frameworks can override via mastery_threshold on framework_states

agreed_level = max(level_ordinal where effective_frequency == "consistent")
  ← derived, never stored
```

---

## Category Pass/Fail

```
capped = max(raw_contribution, -deficit_threshold)
category_pool += capped  per binding in category
category_threshold = category.deficit_threshold || framework.deficit_threshold (default 1.0)
pass if category_pool >= -category_threshold

Overall score uses raw (uncapped) contributions — deficit_threshold does not hide
deficits from the total signal.
```

---

## Promotion Readiness

Evaluated at NEXT level using `level_verdict(next_level)` — same code path as column headers and sidebar verdicts. Contributions are recomputed as if `person_level` were `next_level`. This means the next level's ordinal is expected (1.0), not bonus (0.0). You must demonstrate capability at the next level to be promotion-ready.

Eligible when `level_verdict(next_level) != :below`, which requires both:
1. Score: `performance_ratio_at_level(next_level) >= meeting_expectation_threshold`
2. No `:blocked` capabilities at next level (deficit > deficit_threshold blocks)

Frameworks can override via `meeting_expectation_threshold` on framework_states.

---

## UI Implications

### Capability Matrix Badges

| Signal | When | Display |
|--------|------|---------||
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
|------|-----------|---------||
| Below expectations | `performance_ratio < meeting_expectation_threshold` (default 0.9) OR any :blocked capabilities | Red warning — performance concern |
| Meeting expectations | `performance_ratio >= meeting_expectation_threshold` AND no :blocked capabilities | Green — at or above current level baseline |
| Mastering | `performance_ratio >= mastery_threshold` (default 1.25) AND no :blocked capabilities | Purple — significantly exceeding expectations |
