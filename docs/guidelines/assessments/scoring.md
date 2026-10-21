# Assessments — The Score on Screen

> Part of the [assessments.md](../assessments.md) guide set. Read this when: changing the hero summary, the score's wording or definitions, "How is this calculated?", or which scoring perspective a page shows.

## Hero Summary — three bands

The hero is a single card with three logical bands. The header and bottom line are always visible; only the middle band scrolls away. The middle band renders inside the header's **left column**, under the gloss — beside the number and bar, not below the whole row, so the taller right column never leaves a blank block beside the headline.

```
┌─ #scoring-panel ───────────────────────────────────────────────┐
│  ── Hero header (always visible) ─────────────────────────────│
│  Verdict headline           132%      ← big number on the     │
│  Gloss · parts of the score ▓▓▓▓|▓░░  ← 0–200 bar, ticks at   │
│  [Promo pill] [Continue →]  100·E3 200·E4  the level codes    │
│                                          (left col stacks)    │
│  ── Middle band (collapses on scroll) ────────────────────────│
│  [State label · Gap-to label]                                 │
│   capability-1                              +0.5              │
│   capability-2                              -0.5              │
│   capability-3                              -1.0              │
└────────────────────────────────────────────────────────────────┘
```

### Coverage gate — priming before scoring

Before enough current-level capabilities are rated, the hero does **not** show a score. An unrated cell scores as `0.0` ("never demonstrated") in `PersonDevelopment::Scoring`, so a near-empty assessment would otherwise render a punitive "Below expectations" verdict that only means "you haven't rated yet". `HeroSummary` gates on **current-level coverage** and renders one of three states:

| State | Condition | Hero |
|---|---|---|
| **Priming** | coverage < `COVERAGE_UNLOCK_THRESHOLD` (0.5) | Neutral prompt — "Rate yourself to see your score", `rated/total` big number, progress bar toward the unlock point ("Score unlocks at N"), and a promoted primary "Rate next capability →" CTA. No verdict, no score, no middle gap band, no promotion pill. |
| **Unlocked, incomplete** | 0.5 ≤ coverage < 1.0 | The normal scoring hero (header + middle band) **plus** a small muted "X of Y rated" chip so the partial score reads as honest. |
| **Complete** | coverage = 1.0 | The normal scoring hero, no coverage chip. |

- **Coverage metric** = fraction of capabilities with a cell at `person_level` whose *primary* frequency (per `@context`) is recorded. Measured at the current level only, because the verdict is about that level. Computed entirely inside `HeroSummary` from `@categories` / `@person_level` / `@context` — no `MatrixDataBuilder` change and no threading through the six render sites.
- **`unlock_target`** = `(current_level_total * 0.5).ceil`. The bar fills toward this target (not 100%) — a concrete "Score unlocks at 6" reads as a closer goal than an abstract %.
- **Once unlocked, the score is shown as-is** (option 1) — remaining unrated current-level cells still depress it, and the "X of Y rated" chip is the signal that it will keep moving. We deliberately do **not** score provisionally over only-rated cells (that would let the score *drop* at completion — confusing).
- **`:alignment` context is exempt** — it always shows the scoring hero (individual ratings are frozen by then and coverage is high by construction). A role with zero current-level cells also unlocks, to avoid a permanently-stuck prompt.
- **View-only viewers get passive copy.** A manager-chain ancestor without rating authority (`AssessmentPolicy#rating_participant?` false, threaded as `viewer_can_rate:` from the controller through `ManagerShowView` / `ScoringPanelFrameView`) sees "No score for `<name>` yet" instead of the "Rate `<name>` …" imperative, and neither the priming "Rate next capability" CTA nor the unlocked header's Continue chip renders — those prompt an action the viewer can't take.
- Later: `COVERAGE_UNLOCK_THRESHOLD` could become framework-configurable like the other scoring thresholds.

### Header band

The left column carries the verdict headline, a one-line gloss, and the "bottom line" (promotion pill + Continue CTA). The right column carries the big percentage and the **score bar** — the scale made visible (ADR-21): a two-segment 0–200 track whose left half is the assessed level and right half the next one, tick-labelled with the level codes ("100% · E3", "200% · E4"); at the top of the ladder it is a single 0–100 segment. Both columns sit side-by-side so the card is just tall enough to fit whichever side is taller.

The **verdict headline** follows `performance_state` ("You're meeting E3 expectations." / "well on the way to E4." / "held back at E3 by 1 blocked capability." / "held at E3 until 2 capabilities are rated." / "meeting E8 expectations — the top of the ladder."), and the **gloss** names the score's parts from `scoring[:components]` — "94% of E3 demonstrated · 38% of the way to E4 · 5% missing below E3" — so the headline number never has to be reverse-engineered. Colour tiers read the framework's configured thresholds (`underperforming_threshold` is threaded in alongside the other two); nothing hard-codes 0.8.

Under the big percentage, a tiny secondary line (`#hero-secondary-percents`) shows the other perspectives' percentages (`Self: 118% · Mgr: 101%`), each carrying the shared amber divergence dot when it lands in a different state than the primary. **A secondary perspective is a number, never a second state word** — the gloss used to append "· Self: Below expectations" beside a line that already read "Self: 10%", saying the same thing twice in more space. The state vocabulary is the primary verdict's job, once, at the top of the card; every other altitude (category header, capability card, secondary perspective) is a quick indicator and shows the percentage alone. In alignment — where both Self and Mgr appear — they are ordered **viewer-first** (the viewer's own perspective leads): `Mgr: … · Self: …` for the manager-side viewer, `Self: … · Mgr: …` for the assessee. This is the **same viewer-aware ordering as the split chip** (see [*Misalignment → diagonal split*](../assessments.md)) so the two surfaces tell one story; it's driven by the same `viewer_is_manager:` flag threaded into `HeroSummary`. (In the manager view the only secondary is "Self", so there's nothing to reorder.)

**Once the agreed record is whole, the secondaries are withheld** — from the moment every current-level cell carries an agreed value (`coverage_complete?` in `:alignment`, where the primary frequency is the aligned one), not only after "Mark alignment complete": user testing showed the lingering Self/Mgr numbers on an all-agreed assessment read as competing scores and confused promotion conversations. While cells remain unagreed the secondaries stay — they are the conversation's working material. `alignment_locked:` (threaded into `HeroSummary`) still forces the drop for participants completed before the coverage gate existed. **The hiding is hero-only**: the expansion panel's divergent secondary lines, the level-chip splits (muted post-completion), the category indicators, and the activity feed all keep the self/manager history on drill-in.

The Continue CTA is intentionally small (chip-sized, `text-[11px] px-2 py-0.5`) so it sits inline with the promotion pill instead of looking like a primary action — at the hero level, it's a *nudge*, not the main affordance.

### Middle band — state-driven

A **single** panel framed by `performance_state`. The state picks the headline, tone, and list of capabilities. There is no separate Strengths vs Lift column — that doubled up the story. The state is the headline; the capabilities are the *evidence* for it.

| Performance state | Headline | List label | Items | Border |
|---|---|---|---|---|
| `:underperforming` | "Underperforming at E(n)" | "Gap to E(n)" | 3 weakest gaps at E(n), then "+N more" | red |
| `:progressing` | "Progressing toward E(n)" | "Gap to E(n)" | 3 weakest gaps at E(n), then "+N more" | amber |
| `:performing` | "Performing at E(n) · 38% of the way to E(n+1)" | "Gap to E(n+1)" | 3 weakest gaps **at E(n+1)**, then "+N more" | blue |
| `:mastering` | "Mastering E(n) · 62% of the way to E(n+1)" | "Gap to E(n+1)" | blocked and unrated at E(n+1) first, then the weakest other gaps there; 3 rows, then "+N more" | purple |
| `:eligible` | "Eligible for promotion to E(n+1)" | "Top contributors" | 3 highest scores at E(n) | green |
| `:top_of_ladder` | "Meeting E(n) · top of the ladder" | "Strongest at E(n)" | 3 highest scores at E(n) | blue |

**Every row is a percentage on the same scale as the rest of the page** —
that capability's own score at the level the panel names, tone-coloured by
its state, read from `scoring[:capability_scores]` or
`[:capability_scores_at_next_level]` (the engine's `capability_scores_at`).
It used to print a signed weight-unit delta, which could only be compared
against other rows and — because a capability nobody has rated at the next
level always scores exactly `-1.0` there — showed three identical numbers
that ranked nothing (#418).

**Ties break on the assessed level.** Nothing is rated at the next level
until someone starts working there, so a whole "Gap to E4" list sitting at
0% of E4 is the common case rather than an edge one. Among capabilities
equally unshown above, the one weakest at the level the person is standing
on leads — it has the furthest to go, and the order is then deterministic
rather than whatever the hash happened to hold.

**A capability with no expectation at that level is left out**, rather than
sinking to the bottom of the list on a zero it could never avoid. Before
the change a capability with no expectation at the assessed level appeared
in the gap list at `+0.0`, which is the same "no expectation vs not rated"
confusion the card's "No expectation at E3" copy exists to prevent.

**A gap list holds only gaps, and says when it is not whole** ([#471](https://github.com/mr-yum/growth-os/issues/471)).
A capability already demonstrated in full at the panel's level (100% or
more, and not blocked) is never listed, so a short list is never padded
with capabilities that owe nothing. When none are short, the panel says
"No gaps to E4". When more are short than the three rows it shows, a final
muted line reads "+5 more short of E4 →" and jumps to the fourth through
the shared `ContinueAssessingLink`, at the level the panel names. Three
rows read as the whole list without it: a reader rated one, watched a
fourth take its place, and concluded only three stood between them and
the level. In `:mastering`, blocked capabilities still lead and the rest
follow, so the count covers both. "Top contributors" and "Strongest at"
lists are not gap lists and stay three rows with no count.

**Key insight — always point at the next milestone, never one already cleared.** A `:performing` person isn't trying to *meet* their level (they already do); they're on the way to the next one, and the scale says how far. A `:mastering` person is past the halfway waypoint; the question is what is still in the way of promotion. Both use **next-level** contributions, because progress past 100% is earned at the level above. At the top of the ladder there is no next band, so the panel shows what carries the score rather than a gap nobody can close.

This was the bug that prompted the design: at 110% ratio, the panel originally showed three capabilities at `+0.0` current contribution (meeting exactly) under a "Gap to mastering" headline. That's not a gap — those capabilities ARE meeting expectations. The real gap is at L+1, where those same capabilities show `-1.0` (not yet rated consistent at the next level).

### Collapse on scroll — pure CSS

The middle band collapses to height 0 as the user scrolls past 240px, via a CSS scroll-driven animation:

```css
.hero-collapsible {
  display: grid;
  grid-template-rows: 1fr;
  overflow: hidden;
}
.hero-collapsible > * { min-height: 0; }

@supports (animation-timeline: scroll()) {
  .hero-collapsible {
    animation: hero-collapse linear both;
    animation-timeline: scroll(root);
    animation-range: 0 240px;
  }
  @keyframes hero-collapse {
    to { grid-template-rows: 0fr; opacity: 0; }
  }
}
```

There is **no `sticky_hero_controller.js`** any more. The old binary "compact/expanded" toggle with scroll-compensation logic is gone. CSS scroll-timeline handles every pixel of the transition, no JS in the loop.

Two practical notes:

1. **`grid-template-rows: 1fr → 0fr` rather than `max-height`.** Animating max-height + padding-block inside the unified sticky header was triggering a re-layout feedback loop mid-scroll (visible as a flicker between hidden and visible). The grid-row approach owns the row's height locally, no cascade.
2. **Two-layer wrapper** so the grid item can shrink to 0 without the inner padding forcing a minimum row height. `.hero-collapsible` is `display: grid` with `overflow: hidden`; the grid item is a plain `<div>` (no padding); padding lives on a deeper `<div class="px-5 pb-5">`. When the row collapses to `0fr`, the padded child overflows and is clipped.
3. **Anti-shake guard on the scroll root.** The collapsing band lives inside the in-flow sticky header, so its collapse shrinks layout *above the fold* — which couples scroll position back into the scroll-driven animation and makes the band jitter near full visibility (see Hard-Won Lesson 16). The page's scroll-root wrapper carries `class="assessment-scroll-root"`, which (gated on scroll-driven-animation support) sets `overflow-anchor: none` + a `min-height` floor to break both feedback loops. Both show/manager views apply it; see `app/assets/tailwind/application.css`.

Browser support for `animation-timeline: scroll()` was at ~94% globally as of 2026 (Chrome/Edge 115+, Safari 26+, Firefox 137+). Browsers without it silently keep the middle band fully expanded — functional, just static.

## The explanation layer

The calibration screens have defined their vocabulary in-surface since they
shipped. The assessment side — where the same numbers are read by the person
they describe — defined nothing, and a number nobody can define is one people
either ignore or read as an accusation (#414).

Three pieces, cheapest first:

1. **The bar explains itself** — ticks labelled with the level codes, so
   "100% · E3" and "200% · E4" are on screen before anyone asks.
2. **A definition tip on every scored term the page renders** — the score,
   Blocked, Not rated, No expectation, the rated count.
   `Views::Assessments::Concerns::DefinedTerms#defined_term` renders them
   through `Kit::DefinitionTip`: hover AND keyboard, never the native `title`
   attribute, which no keyboard user can reach. That matters more here than on
   the calibration screens, because the reader is the subject. **A term the
   page never prints gets no tip** — there is nothing to hang it on — so the
   state, Carried and the below-level rule are defined in the drawer below
   instead. The wording is one glossary either way. Weight and Required
   *are* printed now — as the card's chips ([#431](https://github.com/mr-yum/growth-os/issues/431), below) — so they carry
   their tips at the point of reading and are listed in the drawer too.
3. **"How is this calculated?"** in the hero opens
   `Views::Assessments::ScoreExplainerModal` — a root-mounted `Kit::Modal`
   showing **this viewer's own arithmetic first** (shown at E3, shown above
   E3, missing below E3, score) and the rules second. Someone looking at 158%
   wants to know where 158 came from, not to read a definition and do the sum
   themselves. The rows are reconciled against the score before they render,
   so a rounded breakdown always adds up to the total beneath it. Under the
   arithmetic, **"Counts differently for this role"** lists the capabilities
   whose binding changes how a rating lands — weighted, Required, or both —
   wearing the same chips the cards do, read from
   `matrix_data[:emphasised_capabilities]`, which the builder emits beside
   `categories`. The chips there carry no tips, since the rules list beneath
   defines both terms once. The drawer used to define "weight" for a list
   the reader could not see.

`Views::Assessments::Glossary` is the single source of the wording, built per
request rather than frozen as constants, because nearly every definition has
to name something only this page knows: the viewer's level codes, the
framework's configured bands, and the tenant's word for each state. Copy that
says 80% where the framework says 75% is worse than no copy at all — which is
why `thresholds:` is threaded from `MatrixDataBuilder` down to every surface
that defines a term, via `Glossary.thresholds_from(matrix_data)`.

Rules for the copy, pinned by `test/components/assessments/glossary_test.rb`:

- **Never a model word** — no band, gate, tolerance, ratio, perspective,
  component, deficit, binding, ordinal. The reader did not build the engine.
- **Always their own codes and numbers**, never "your level".
- **Say what does NOT count**, since that is what people assume wrongly:
  feedback and comments are not an input to the score, levels below the
  assessed one are assumed met, unrated is not a zero, carried is not
  confirmed.
- **A definition has to stand on its own.** It is read beside the word it
  defines AND as a bullet in the drawer, where there is no word beside it —
  so "This capability counts for more", "nobody has rated here yet" point at
  something the list cannot show. Write the subject out. The exception is a
  term rendered ONLY as a tip (Blocked, on its badge), which may point at the
  thing it is attached to; the rule is asserted over the drawer's rendered
  bullets rather than over every term, so that stays legal.

`SCALE_SENTENCE` — the scale stated without naming a level — is shared with
`Views::CalibrationSessions::Glossary`'s `pct_of_expected`, where the axis
spans people standing at different levels and no single code is true for the
column. Everywhere a code IS known, the copy names it instead.

### The process, before the numbers

The explanation layer defines what a score means. `/assessments/how-it-works`
(`Views::AssessmentGuides::ShowView`) explains the process around it: an
illustrated walk through one cycle (set up, rate and gather, align, close),
the participation statuses, and the four rules that keep it fair. Any tenant
member may read it (`AssessmentGuidePolicy`); it shows no one's data. Rules
for keeping it honest:

- **Draw with the real vocabulary.** Chips, the rating scale and the split
  take their classes from `FrequencyPalette` and `LevelChip`, so a palette
  change reaches the guide too.
- **Read tenant settings, never restate them.** The state word comes from
  `StateLabels`, the unlock count from `HeroSummary.unlock_target_for`.
- **It is not an MCP surface.** It carries no data an agent could act on;
  the tool descriptions already explain the same process.

## Multi-perspective scoring

`Assessments::MatrixDataBuilder` builds four parallel scoring outputs:

| Key | Perspective | Frequency Used |
|---|---|---|
| `scoring` | `:effective` (default) | Fallback chain: aligned → manager → self |
| `self_scoring` | `:self_only` | Only `self_rated_frequency` |
| `manager_scoring` | `:manager_only` | Only `manager_rated_frequency` |
| `aligned_scoring` | `:aligned_only` | Only `aligned_frequency` |

Each uses `PersonDevelopment::Scoring` with a different `perspective:` parameter. Returns `nil` (not empty hash) when no ratings exist for that perspective — `HeroSummary` falls back to effective when its preferred perspective is nil.

Every perspective hash now carries a `performance_state` symbol (see [scoring-model.md](../../architecture/scoring-model.md)) and, when the person isn't at the top of the level ladder, a `capability_scores_at_next_level` map keyed by stable_id — each capability's own score at the level above, from the engine's `capability_scores_at`. The hero's middle band uses both to pick its narrative — see *State-driven panel* above.

## Performance state machine

Defined in `PersonDevelopment::Scoring#performance_state`. See [scoring-model.md](../../architecture/scoring-model.md) for the canonical definition. Summary:

```
:underperforming  score < underperforming_threshold (default 0.80)
:progressing      underperforming_threshold ≤ score < meeting_threshold
                  OR any capability held (blocked, or unrated)
:top_of_ladder    meeting, and no level above this one
:eligible         promotion_readiness[:eligible]
:mastering        score ≥ mastery_threshold (default 1.50) AND not eligible
:performing       otherwise (meeting_threshold ≤ score < mastery_threshold)
```

Precedence: underperforming → progressing → top_of_ladder → eligible → mastering → performing.

`MatrixDataBuilder` exposes the state on each perspective's scoring dict via `performance_state: scoring.performance_state`. The hero's `state_panel_config` is a `case` over this single symbol.
