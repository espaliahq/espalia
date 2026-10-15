# Assessment UX — Design & Architecture

This document captures the design decisions, interaction patterns, and hard-won lessons from building the assessment views (self-assessment, manager assessment, and alignment). Consult this before modifying assessment UX or building features that extend it.

> **See also:** [scoring-model.md](../architecture/scoring-model.md) for the scoring engine, performance-state vocabulary, and configurable thresholds.

> **Terminology — "Feedback / Evidence" on the surface, "evidence" in the domain.** User testing showed the bare word "evidence" discouraged people from contributing constructive feedback, so the **user-facing UI and the MCP tool descriptions** call this concept **"Feedback / Evidence"** (prominent labels, nav, headings, modal titles) or **"feedback"** (running prose, flashes, activity-feed sentences, notifications). The **domain vocabulary is unchanged**: events, commands, handlers, read models (`EvidenceItem`, `EvidenceRequest`, `EvidenceLink`), DB columns, form param namespaces (`evidence[...]`), routes (`/evidence`), Stimulus controllers (`evidence-modal`, `request-evidence`), turbo-frame ids, the `data-glyph="evidence"` attribute, activity `KIND_GROUP`/kind values (`evidence_recorded`…), and the MCP **tool names** (`assessments_record_evidence`…) all stay "evidence". The relabel is presentational only — no migration or projection rebuild. When adding a surface, follow the same split: label it "Feedback / Evidence", keep the identifier "evidence".

## Overview

The assessment UX is a **card-based, single-scroll** layout. The page renders one tall document — a unified sticky header on top, then a vertical stack of category sections, each containing a stack of capability cards. There is no matrix table and no tabbed category swap. Category chips in the header anchor-jump to the section below; the entire document is in view at all scroll positions.

Three coordinated surfaces share the page:

```
┌──────────────────────────────────────────────────────────────────────┐
│  Unified sticky header (sticky top:0)                                │
│  ┌───────────────────────────────────────────────────────────────┐   │
│  │ Back link · H1 (assessee or level title) · status pill        │   │
│  │ ─── Hero summary card ─────────────────────────────────────   │   │
│  │   Hero header (verdict + 91% + bar + bottom-line CTA)         │   │
│  │   Middle band (collapses on scroll, see "State-driven panel") │   │
│  │ ─── Category chip bar ─────────────────────────────────────   │   │
│  │   [All 18] · [Thinking & Delivery] · [Collaboration] · …      │   │
│  └───────────────────────────────────────────────────────────────┘   │
├──────────────────────────────────────────────────────────────────────┤
│  Main column (scrolls beneath the sticky header)                     │
│    ┌─ Category section: Thinking & Delivery ──── [Pass] ─┐           │
│    │   sticky sub-heading (sticks below unified header)  │           │
│    │   ┌─ Capability card ──────────────────────────────┐│           │
│    │   │ THINKING · Critical Thinking      +0.5         ││           │
│    │   │ Level strip: E1 E2 E3(YOU) E4 E5 …             ││           │
│    │   │ Expansion panel for person_level (auto-focused)││           │
│    │   └────────────────────────────────────────────────┘│           │
│    │   ┌─ Capability card ──── … ┐                      │            │
│    │   └─────────────────────────┘                      │            │
│    └────────────────────────────────────────────────────┘            │
│    ┌─ Category section: Collaboration & Communication ──┐            │
│    └────────────────────────────────────────────────────┘            │
│                                                                      │
│  Activity sidebar (right) — slide-over on narrow, inline on wide     │
└──────────────────────────────────────────────────────────────────────┘
```

The matrix Turbo Frame still exists and still carries `id="assessment-matrix"`, but its inner content is now the category-sections-with-cards stack rather than a table.

### URL-driven state

Active category, focused capability, and focused level ordinal are encoded as query params for shareability:

```text
Browser:      /assessments/:id?category=<category_id>&capability=<stable_id>&level_ordinal=<n>&levels[<stable_id>]=<n>…
Matrix frame: /assessments/:id/matrix?category=<category_id>&capability=<stable_id>&level_ordinal=<n>&levels[<stable_id>]=<n>…
Activity:     /assessments/:id/activity?capability=<stable_id>&level_ordinal=<n>
```

- `category` absent → server defaults to the first category for highlighting in the chip bar; all categories still render in the document.
- `capability` is the capability's **stable_id** (cross-version UUID), never the per-version `capability_id`.
- `level_ordinal` only honoured when `capability` is also present.
- **`levels[<stable_id>]=<ordinal>` is the per-capability selected-level map** — the **rendering** axis, distinct from the single-cell **focus** axis (`capability`/`level_ordinal`). Each capability card's expansion panel renders the level the viewer last selected for THAT capability; the map **accumulates** one entry per capability the user picks a level on. This is what makes a level selection persist *independently per capability* across scrolling, rating, and live broadcast reloads — selecting a level on one capability never resets another (the old single-slot model did). `AssessmentsController#selected_levels_param` parses it (and folds in the legacy single `capability`/`level_ordinal` pair, so deep-links / the Continue CTA / activity-feed navigation still render the focused card at the requested level); `CapabilityCard` resolves its displayed ordinal as `selected_levels[stable_id] || person_level`. **The scroll-driven capability picker only ever touches `capability`/`level_ordinal`, never the map** — so scrolling can't disturb a rendered level. The map is threaded into the matrix frame `src` (`matrix_frame_params`) and re-merged onto the `src` on every broadcast reload (`assessment_sync_controller#mergeFocusParams`, alongside `capability`/`level_ordinal`), so a rating/alignment broadcast keeps every card on its selected level. URL length grows only with explicitly-changed capabilities (default-level cards aren't in the map).
- Every capability card auto-focuses the person's current level on render (the expansion panel is always visible for `@person_level`). A `levels[<stable_id>]` entry (or, for back-compat, the focused `?capability=` + `?level_ordinal=` pair folded into the map) overrides — the card's expansion panel renders for the selected level instead.
- `matrix_controller#syncFocusToUrl` writes `capability` and `level_ordinal` together in **one** `history.pushState` per focus change, so Back/Forward maps 1:1 to visible focus changes. `matrix_controller#reloadMatrixWithFocus` additionally merges `levels[<stable_id>]=<ordinal>` into both the frame `src` and the browser URL on every chip click (accumulating), so the per-capability map stays current for reloads and sharing.
- Category chip clicks update the URL with `?category=` and dispatch a `matrix:focus-changed` event at category level so the activity feed narrows.

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

Under the big percentage, a tiny secondary line (`#hero-secondary-percents`) shows the other perspectives' percentages (`Self: 118% · Mgr: 101%`), each carrying the shared amber divergence dot when it lands in a different state than the primary. **A secondary perspective is a number, never a second state word** — the gloss used to append "· Self: Below expectations" beside a line that already read "Self: 10%", saying the same thing twice in more space. The state vocabulary is the primary verdict's job, once, at the top of the card; every other altitude (category header, capability card, secondary perspective) is a quick indicator and shows the percentage alone. In alignment — where both Self and Mgr appear — they are ordered **viewer-first** (the viewer's own perspective leads): `Mgr: … · Self: …` for the manager-side viewer, `Self: … · Mgr: …` for the assessee. This is the **same viewer-aware ordering as the split chip** (see *Misalignment → diagonal split*) so the two surfaces tell one story; it's driven by the same `viewer_is_manager:` flag threaded into `HeroSummary`. (In the manager view the only secondary is "Self", so there's nothing to reorder.)

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

## Category navigation

Five surfaces, all reading from the same `?category=` URL state:

1. **Chip bar** in the sticky header. Anchor links to `#category-<id>`. Active chip has `aria-current="page"` and a dark fill. Click is intercepted by `category_nav_controller#scrollTo` (smooth-scrolls, accounting for sticky header height) and pushes the new `?category=` to the URL.
2. **Category sections** in the main column. Each `<section id="category-<id>">` has a sticky inner heading that pins just under the unified header at `top: var(--sticky-header-h)`. `category_nav_controller#publishHeaderHeight` measures the unified header with `getBoundingClientRect().height` (sub-pixel precision) and writes it to a CSS custom property via `ResizeObserver`.
3. **Scroll-based active marker**. As the user scrolls, `category_nav_controller#updateActiveCategory` finds the deepest section whose top has scrolled past the threshold and marks its chip active. Suppressed for ~900ms after a chip click so the explicit click result survives the smooth-scroll animation (otherwise the final scroll event of the animation could fall short of the threshold and re-mark the previous chip).
4. **Activity sidebar**. Listens for `matrix:focus-changed@window` with `level: "category"` and narrows its rendered entries.
5. **Server state**. The controller reads `?category=` only to render the active chip class — the document includes every category section regardless.

### The category's score — `CategoryIndicators`

The section heading carries the category's score on the same scale, one
altitude above the card: the rated count, the split when it adds anything,
the tone-coloured percent, and a `:md` `ScoreBar`. Rendered as a single
Turbo Stream target (`category-indicators-<id>`) so a rating updates the
whole cluster atomically.

- **A quick indicator shows a number, not a word.** The state word is a
  `title` on the percent (and `data-category-state` for tests), never
  rendered text. A category header is scanned, not read; "75% Underperforming"
  is wider than the column and says twice what the colour already says.
  Divergent secondary perspectives read "Self: 45%" for the same reason.
  The hero is the one altitude that spends a line on the state vocabulary.
- **Coverage gate, per perspective.** Until at least half of the category's
  assessed-level cells carry the viewer's rating, the header shows "1/4
  rated · score unlocks at 2" instead of a number, and the **chip bar**
  hides that category's state dot and percent on the same rule. A category
  nobody has touched must not read as underperforming. The gate applies to
  each **secondary** perspective against *its own* ratings too — a manager
  who has rated everything must not read "Self: 0%" as a verdict when the
  assessee has not started. `Assessments::SecondaryPerspectives` is the one
  place the list is built (the section header and all three rating
  controllers' Turbo Stream responses), and each entry carries its context
  so the gate has ratings to count.
- **The description gets its own row.** The name shares its line with the
  score cluster (which wraps below it on a narrow viewport); the
  description runs full width underneath at `max-w-3xl`. Sharing one row
  with a ~14rem cluster left it a ribbon four or five words wide and six
  lines tall inside a *sticky* header — prose needs the column, and a
  category name is short enough not to.

## Capability focus

Sits between category focus and cell focus in the focus hierarchy. Narrows the activity sidebar to a single capability without committing to a specific level (the latter is cell focus, set by chip click).

Two ways to trigger it:

**Card-header click.** Clicking the card's header region (eyebrow + capability name + description) sets capability focus. Wired with `data-action="click->matrix#focusCapability"` scoped to the header (not the whole card) so clicks on the level strip and inside the expansion panel — which carry their own focus and interactive affordances — never accidentally land here. Re-clicking the same focused card's header toggles back to category focus, mirroring `focusCategory`'s behaviour. The header's text stays selectable, so a capability name can be copied: a click that ends with text selected in the header (a drag or a double-click) leaves focus alone ([#492](https://github.com/mr-yum/growth-os/issues/492)).

**Scroll-driven focus.** An `IntersectionObserver` on `matrix_controller` (rootMargin `0px`, broad threshold list) tracks every card touching the viewport. On every intersection change, `#updateFocusedCapabilityFromScroll` picks the card with the **most visible area** in the **content band** — the viewport strip below the sticky chrome (`y ∈ [sticky-header-h, viewport.height]`). Whichever card occupies the most screen real estate is what the user is reading.

This rule is symmetric: scrolling down, the new card's visible area grows from below until it exceeds the previous card's shrinking area, and focus switches; scrolling up reverses the same crossing in the opposite direction. The previous threshold-based heuristic ("deepest card whose top has crossed below the sticky-chrome bottom") was symmetric in mechanism but produced asymmetric perception — scrolling down the new card appeared naturally at the threshold line, but scrolling up the trigger fired when the current card's top crossed back above that line, often well before the returning card was meaningfully on-screen. Area-based picking removes that asymmetry entirely.

**Gating on scroll-driven updates** — three rules, each load-bearing:

- **Wait for a real user scroll.** `IntersectionObserver`'s initial callback fires on connect with the cards' current intersection state, not in response to a user scroll. Acting on that would override URL- and click-driven initial focus and silently auto-narrow the activity feed on page load. `_sawUserScroll` flips on the first `scroll` event; until then `#updateFocusedCapabilityFromScroll` no-ops.
- **Cell focus is sticky-but-not-permanent.** When the user has explicitly clicked a chip, `currentFocus.level === "cell"` and scroll-driven updates leave the focus alone as long as the focused capability is still the area-winner. The moment a different card overtakes it, cell focus downgrades to capability focus on the new winner — the sidebar re-narrows to whatever the user is now reading. Re-clicking a chip restores cell focus.
- **Two-layer suppression around explicit clicks: time-based AND renew-on-scroll.** Card-header clicks, chip clicks, and any other explicit focus action set `_capabilityFocusSuppressUntil = Date.now() + 1800` (time-based) AND flip `_suppressionScrollRenew = true` (renew-on-scroll). Every scroll event during the suppression window renews a 2000ms settle timer; when scroll events stop for 2000ms the flag clears. The time-based window covers the explicit click itself; the renew-on-scroll layer covers the variable-duration smooth scroll that follows. A fixed time window alone was too brittle on slow CI — the smooth scroll routinely outlasted 1800ms there.
- **Respect external focus events.** `matrix_controller` listens for `matrix:focus-changed` on the window so any external dispatcher (today: `category_nav_controller` on chip click) can drive the controller's `currentFocus` and trip the same dual suppression. Without this, a category chip click would dispatch category focus to the activity sidebar, start a smooth scroll, and let the IntersectionObserver immediately overwrite the focus with whichever capability landed in the band first. Self-dispatch from `matrix_controller`'s own actions carries `source: "matrix"` on the event payload so the listener can skip it.
- **External category focus is sticky like cell focus.** When a chip click puts us in category focus, `#onExternalFocusChange` sets `_categoryFocusFromExternal = true`. The scroll picker checks this flag the same way it checks for same-card cell/capability focus and refuses to downgrade — even after suppression releases on the next scroll tick. The flag clears on the next explicit non-category focus action (card-header click, level chip click), at which point scroll-driven capability picking resumes normally. Initial default category focus from `#dispatchInitialFocus` does **not** set the flag, so the first user scroll on a fresh page still narrows to capability focus.

**URL semantics.** Capability focus is transient; it does NOT write `?capability=` to the URL. That parameter remains owned by cell focus (chip click), where the server uses it to render the expansion panel for the named level. `#setFocus` accepts `{ pushToUrl: false }` for scroll-driven updates so continuous scrolling doesn't thrash `history.pushState`; explicit card-header clicks DO push to URL (default `pushToUrl: true`) — making them as shareable as cell focus.

**Visual styling.** A focused card carries `data-focused="true"`; styling hangs off Tailwind data variants:

```ruby
"data-[focused=true]:shadow-sm data-[focused=true]:ring-1 data-[focused=true]:ring-primary/20"
```

Server stamps it from `?capability=` on initial render; `matrix_controller#applyCardFocus` toggles it on focus changes. Single source of truth.

**Activity feed reconnect.** `activity_feed_controller#readMatrixFocusFromDom` reads `data-focused="true"` on a card to restore capability focus when its turbo-frame lazily loads. Without this signal, a lazy frame load would silently downgrade to category focus and undo the user's last click.

### Focus hierarchy (most specific wins)

| Level | Trigger | URL params written | Persists across |
|---|---|---|---|
| `framework` | Default / "Show all" link | — | — |
| `category` | Category chip click; scroll-based category active marker | `?category=` | Browser navigation. Chip-click also sticky against scroll picker via `_categoryFocusFromExternal`. |
| `capability` | Card-header click; scroll-driven IntersectionObserver | `?capability=` (click only) | Click: browser nav. Scroll: transient |
| `cell` | Level chip click; URL deep-link | `?capability=` + `?level_ordinal=` | Browser navigation |

The activity sidebar consumes the most specific currently active focus level. Each level's `#matchesFocus` check uses progressively narrower criteria — category by `category_id`, capability by `capability_stable_id`, cell by both stable_id and `level_ordinal`.

## Capability cards

Each capability gets its own bordered card inside its category section:

```
┌─ Capability card ────────────────────────────────────────┐
│ THINKING & DELIVERY                  +0.5    [Add evidence]│
│ Critical Thinking                                          │
│ Considers long-term impact, balances competing priorities.│
│                                                            │
│   E1   E2   E3◯   E4   E5   E6   E7   E8                  │
│        YOU (with focus ring)                               │
│                                                            │
│ ── Expansion panel for the focused level ────────────────│
│   E3 · Senior Software Engineer                            │
│   Expectation text for E3 …                                │
│   Demonstrates: [Not yet ▾]   ○ Self rating: Some of the time│
│   EXAMPLES (illustrations for this level)                  │
│   EVIDENCE  +                                              │
│   COMMENTS  +                                              │
└────────────────────────────────────────────────────────────┘
```

Structure: `card_header` (eyebrow + name + signed delta + add-evidence) + `LevelStrip` + `CapabilityCardExpansion` for the focused level.

### Auto-focus on the person's level

Every card auto-focuses the person's current level on first render — the expansion panel is *always* visible for `@person_level`. The viewer overrides a card's level by clicking a chip; that selection is remembered **per capability** in the `levels[<stable_id>]` URL map (see *URL-driven state*), so `CapabilityCard` resolves its displayed level as `selected_levels[stable_id] || @person_level`. Selections are independent and persistent across scrolling / rating / reloads — picking a level on one card never resets another. There is no longer a "default" state with the strip but no panel.

There is no `×` close button. The previous design had one to drop back to "no level focused"; with auto-focus there's nothing meaningful to close *to*. Re-focusing means clicking a different level chip — handled by `matrix_controller#focusChip`, which sets the URL and reloads the matrix frame.

### The capability's own score — `CapabilityNameRow`

The name row carries the capability's score **on the same scale as the hero**
(ADR-21), rendered by `Views::Assessments::CapabilityNameRow` inside
`id="capability-name-<stable_id>"` so the rating controllers' Turbo Streams
replace it with the same view that first drew it. One scale at three
altitudes — hero, category header, capability card — all reading
`Views::Assessments::Concerns::ScoreScale` for tone, state words and level
codes, and all drawing `Views::Assessments::ScoreBar` at their own size.

Three rules, each load-bearing:

- **Never the net alone.** The row shows the split beside the number
  (`50% · +50% toward E4`, plus `−N% below` when a prior level is short),
  because under the multiplicative gate "most of the time" at the assessed
  level with "consistently" above it nets to 100% next to a pill that says
  "Most of the time". The split is dropped only when it would restate the
  number — a lone `75%` beside a `75%` is noise — and hides below `sm`.
- **Unrated is not 0%.** A capability whose assessed-level cell carries no
  rating in the viewer's perspective reads **"Not rated"**; one with no
  expectation at that level reads **"No expectation at E3"**. Both would
  otherwise score 0.0 and read as a verdict on the person.
- **Only a rating can block ([#485](https://github.com/mr-yum/growth-os/issues/485)).**
  The Blocked badge reads the engine's `:blocked` status, which counts rated
  cells only, so "Not rated" never sits beside it on an unrated card. It used
  to: the unrated 0 blocked like a "not yet", and a fresh assessment wore
  Blocked on every card. The two can still appear together for a reason: a
  rated "not yet" below the assessed level blocks while the assessed level
  waits on its rating. An unrated capability still holds the state — or
  leaving one unrated would beat rating it "not yet" — and the hero says so
  without the word: "held at E3 until 2 capabilities are rated" when the
  score clears the bar, "close to E3 expectations, with 2 capabilities still
  to rate" when it doesn't, so it never promises a rating will lift a score
  that is short anyway.
- **The colour is the state, not the number.** The percent takes
  `tone_text(state)` from the engine's per-capability state (blocked →
  amber), so a card can't read green while the hero says held back. The
  state *word* is a `title`, never rendered text — see the category header
  rule below.

**The binding facts come before the score ([#431](https://github.com/mr-yum/growth-os/issues/431)).** Between the name and the
Blocked badge the row wears up to two muted chips: **`×2`** when the
binding's weight is not 1, and **"Required"** when the resolved tolerance is
0. Both ride the per-capability score hash the row already reads
(`scoring[:capability_scores][stable_id][:weight]` / `[:required]`), stamped
by `MatrixDataBuilder#extract_scoring` from the engine's own `mandatory?`, so
the chip and the block gate cannot disagree and no render site threads them
by hand. Rules:

- **Shown before any rating, not after the damage.** Blocked is a state that
  appears once a rating shows a gap; Required is the standing fact that a gap will
  block. Both had definitions in the explainer drawer and appeared nowhere on
  the page, so a Required capability's first sign of being special was the
  Blocked badge.
- **Grey, never the state colour.** Colour beside a score means state; a
  weight is a property of the framework, not a verdict on the person.
- **Nothing for the common case.** No `×1`, no "Tolerated" — a chip only
  appears where it changes the reading. Most capabilities are 1.0, and the
  chip earns its place by being rare.
- **Defined where it is read.** Both go through `defined_term`, so they are
  keyboard-reachable and carry the glossary definition. The same helpers
  (`DefinedTerms#weight_chip` / `#required_chip`) draw the hero gap list's
  `×N` marker; `ScoreScale#weight_label` is the one spelling of a weight and
  `PersonDevelopment::Scoring.weighted?` the one test for it, shared with the
  explainer's plain chips and the calibration cohort drawer's `×2` marker.
  That marker stays a `title`-only span by design: it belongs to the
  calibration glossary, not this one.

The signed `±N.N` delta this replaced is gone from the card. It was in the
engine's raw units, so it could only be compared against other capabilities,
never against an expectation; the scale it now shows answers "how am I doing
here" directly. The hero's gap lists read `capability_scores` and
`capability_scores_at_next_level`, the same per-capability scores on the
same scale.

### Level strip — `LevelStrip` + `LevelChip`

A horizontal `flex` of `LevelChip`s, one per merged level ordinal. Each chip is colored by frequency × level position (same color rules the old matrix cells used). The assessee's current-level chip carries a badge — **"YOU" in self context, "CURRENT" in manager / alignment context** (the level belongs to the report, so "YOU" would mislead the manager) — and a darker outline when focused. Click dispatches `click->matrix#focusChip`, which sets `?capability=` + `?level_ordinal=`, reloads the matrix frame, and smooth-scrolls the card under both sticky headers (unified + category section).

The chip strip wraps `overflow-x-auto -mx-4 px-4` so it scrolls horizontally on narrow viewports without breaking the card's padded edges.

### Scroll-to-card after chip click

When a chip is clicked, `matrix_controller#scrollCardUnderHeader` smooth-scrolls the card so its top sits just below **both** sticky elements: the unified header AND the category section's sticky inner heading. Missing the section header was the most common scroll bug — the card top would land behind it. A post-animation settle pass re-snaps if the hero collapses mid-scroll.

```js
const target = Math.max(0, cardTopDoc - unifiedHeaderH - sectionHeaderH - 12)
window.scrollTo({ top: target, behavior: "smooth" })
setTimeout(reSnapIfDrifted, 600)
```

## Context-Driven Rendering

A single `context` symbol (`:self`, `:manager`, or `:alignment`) threads through the entire request — from controller detection to form action URLs.

```ruby
# assessments_controller.rb
def assessment_context
  return :alignment if cycle_in_alignment_phase?
  manager_viewing? ? :manager : :self
end
```

Routes to:
- **Self** (`context: :self`) → `ShowView` — person rates themselves. Manager and aligned ratings are hidden — see *Self-assessment privacy* below.
- **Manager** (`context: :manager`) → `ManagerShowView` — manager rates their direct report. **An active rating delegate gets this same view** (`manager_viewing?` is true for them), so they review and rate exactly like the manager — minus the alignment actions. **Any other manager-chain ancestor (skip-level and above) — and a tenant/global admin outside the chain — also gets this view, read-only**: `AssessmentPolicy#show?` admits the whole chain (`Person#managed_by?`) plus `tenant_admin?` (HR view), and `AssessmentsController#apply_viewer_rating_lock` forces `individual_ratings_frozen` for a viewer without rating authority, so their pills render static instead of 403ing on click.
- **Alignment** (`context: :alignment`) → automatic once `cycle status ∈ {aligning, aligned}`. Both parties see all three rating perspectives. A delegate or chain ancestor sees alignment **read-only** (`view_alignment?` includes them; `apply_viewer_rating_lock` forces `alignment_locked` for viewers who can't record alignment) but can never record/start/complete it. There is no opt-in URL param and no in-page toggle.

See *Manager-rating delegation* below for the full delegate model.

### Self-assessment privacy

The assessee must not see the manager's rating until alignment formally begins. Enforced at two layers:

1. **Data layer** — `Assessments::MatrixDataBuilder` accepts a `context:` kwarg. When `context == :self`, manager and aligned data are scrubbed from the result — `manager_frequency` / `aligned_frequency` per cell, plus `manager_scoring` / `aligned_scoring` at the top level. The primary scoring perspective is forced to `:self_only`.
2. **Policy layer** — `AssessmentPolicy#view_alignment?` requires the participant's cycle status to be `aligning` or `aligned`. Until the manager has formally started alignment, the assessee renders in `:self` context regardless of any URL params.

### How context flows through components

| Component | What context determines |
|---|---|
| `MatrixDataBuilder` | Which scoring perspective is primary; whether manager/aligned data is scrubbed |
| `HeroSummary` | Which `*_scoring` hash to render (`self_scoring` vs `manager_scoring` vs `aligned_scoring`); subject pronoun ("You're" vs "Alex is") |
| `CapabilityCard` / `LevelChip` | Which `*_frequency` colors the chip; whether the chip splits on disagreement |
| `CapabilityCardExpansion` | Which perspective the `FrequencyPill` rates; which `SecondaryRatingLine`s render |
| `FrequencyPill#form_action` | POST endpoint — `/ratings` (self) vs `/manager_ratings` (manager) vs `/alignment_ratings` (alignment) |

## Manager-rating delegation

When a report is **seconded into another team**, their reporting manager loses
direct visibility and can delegate the **manager rating** (but never alignment)
to someone closer to the work. Authority is enforced in Pundit AND, as a
defense-in-depth domain invariant, in the PersonDevelopment aggregate — see
[authorization.md](authorization.md#assessment-permissions) and
[person-development-aggregate.md](../architecture/person-development-aggregate.md).

- **Who is the manager** is recorded-authoritative: `RecordedReportingManager`
  (an event-sourced fact on the stream) is the source, with a live
  `Person.manager_id` fallback when nothing is recorded.
- **Delegate's experience** — the delegate sees the report in their index
  ("Team Assessments", unioned by active delegation) and opens the same
  `ManagerShowView`; they record manager ratings normally and see alignment
  read-only once it starts. They are treated like a manager for activity-feed
  visibility (`viewer_sees_all_evidence?` returns true for an active delegate)
  so they see the very ratings they record.

**Granting UI (manager view header).** The action cluster gains a **"Delegates ·
N"** button shown only when `@can_manage_delegates` (`delegate_manager_rating?` —
ancestor manager or tenant admin; the delegate never sees it). It opens a
`Kit::Modal` (standalone) whose body is the `delegations-list` Turbo Frame:

- A person `<select>` (candidates from
  `ManagerAssessmentDelegation.candidate_people`, excluding assessee / granter /
  current delegates) + optional `expires_at` + a submit.
- An active-delegate list, each with a ✕ revoke (`data-turbo-confirm`).

`Assessments::DelegationsController#create`/`#destroy` dispatch
`Operations::Assessments::{DelegateManagerRating,RevokeManagerRatingDelegation}`
(`approval :in_app`) and re-render the `delegations-list` frame so grant/revoke
update **in place** without closing the modal (200 on success; 404/422 on
failure — Turbo renders the frame either way). Expiry is **lazy** (filtered by
the `active` scope at read time); an expired grant can be **renewed** (the
aggregate's idempotency is expiry-aware).

**Activity feed.** Three framework-scoped entry kinds surface under "All" only
(no new filter chip — their `KIND_GROUP` is outside `CHIPS`):
`delegation_granted`, `delegation_revoked` (manager-rating privacy gate —
visible to manager + delegate, hidden from peers and from the assessee
pre-alignment), and `reporting_manager_recorded` (not sensitive → visible to any
viewer; only emitted on an actual manager change). A delegate's manager rating
renders a **"(delegate)" badge**, driven by `via_delegation` stamped on the
rating event at write time (accurate at event time — not reconstructed from
current state).

## Role lens

A person can be read against a role or level they are not in — "how would I read as a PM3?" — without touching the assessment of record. The model is [ADR-22](../architecture/adrs.md): **a rating is a fact about the person at a capability × level; roles choose which of those facts count.** Built in phases ([role-lens-plan.md](../notes/role-lens-plan.md)): the scope guard, the lens, per-role alignment and declared explorations.

| Term | Meaning |
|---|---|
| **Home role / home level** | The role and level the cycle's enrollment snapshot assesses the person at (ADR-19). What the record is. |
| **Lens** | A `(role, level)` the page is *read against* — `as_role` / `as_level` in URLs and Operation params. The home role is the default lens. |
| **Role scope** | The `(capability_stable_id, level_ordinal)` cells a role's active bindings and expectations define — `Assessments::RoleScope`. |
| **Out-of-scope cell** | A cell outside the home role's scope. Rated into the same cycle; invisible to every home-role reader. |
| **Disclosed cell** | A cell whose manager and aligned ratings the assessee may see: the union of the scopes of every role whose alignment has started in this cycle. |
| **Per-role alignment** | Alignment started, completed and re-opened *against a role*. Home alignment is the same thing against the home role. |
| **Declared exploration** | A `(person, framework, target role, target level)` intent fact on the PD stream, with a lifecycle. Not a rating scope. |

Avoid "aspirational assessment", "what-if", "shadow ratings" and "exploration ratings": each implies a second copy of the truth, and there is only one rating per cell.

- **Disclosure is per role.** A manager rating on a cell reaches the assessee only once alignment has started against a role whose scope contains that cell — the home rule (see *Self-assessment privacy*) applied per role. There is no side channel: disclosure is the one deliberate act of starting alignment.
- **Freeze is per cell; completion is per role.** A cell freezes once any started role's scope contains it, and each role's completion gate counts only that role's current-level cells.

### Reading through a lens

- **One lens per request.** `Assessments::Lens.resolve(assignment:, as_role:, as_level:)` returns the role and level read against plus the home they are read from — the open cycle's enrollment snapshot, else the live assignment. `as_level` is an ordinal; `as_role` alone picks that role's level nearest the home ordinal (ties go lower). A pair the framework doesn't have raises `Lens::NotFound`, a `RecordNotFound` that `config/application.rb` maps to 404 (Rails matches exception classes by name, so the subclass needs its own entry). The controller resolves it after `authorize`, so a stranger gets the denial, not the 404.
- **Everything builds through it.** `Assessments::MatrixDataBuilder.for_lens(lens:, context:, …)` is the one entry point for the page, its frames, the rating controllers' Turbo Stream re-renders and `Assessments::ScoreSummary` (MCP). The builder reads the lens role's cells, scores against the lens level with the home level as the floor (below), marks each capability `in_home_role` and each cell `in_home_scope`, and returns the lens as `matrix_data[:lens]`.
- **URL params and frames.** `as_role` / `as_level` ride the page URL, the matrix and scoring frame `src`s and every rating pill's form, so a re-render reads the same lens. `assessment_sync_controller#mergeLensParams` copies them from the browser URL onto a frame `src` before a broadcast reload, exactly as it does `levels[]` — without it the first rating from elsewhere snaps the page back to the home role. The activity frame carries no lens: the feed is the person's history and reads the same under any lens. The rating controllers resolve the lens before writing, so a stale `as_level` is a 404 that changed nothing, and an Operation's refusal renders the pill's error line (403 with a body — a bodyless 4xx shows as nothing).
- **The floor.** `PersonDevelopment::Scoring` takes `home_level:`; an unrated cell counts as consistent only below both the lens level and the home level. The level chips paint the same floor (`matrix_data[:assumed_below]`), so an E2 read as E4 shows E3 grey, not assumed-blue.
- **Disclosure is per cell.** `Assessments::Disclosure.for(lens:, participant_status:)` names the cells whose manager and aligned values the assessee may see — the union of the scopes of every role whose alignment has started this cycle: the home scope once home alignment is `aligning` / `aligned` (the participation's status), plus each other role's scope once its `AssessmentCycleRoleAlignment` row exists. The set does not depend on the lens. The builder scrubs every other cell in `:self`, the activity feed hides the manager-rating and revisit entries on those cells from the assessee (per cell, for the open cycle), and the MCP drill-in scrubs them too. `Assessments::ViewerContext` reads a lens on another role as `:alignment` only once alignment has started against that role. So through a PM lens after home alignment, a shared cell shows its "Manager rating" line and a PM-only cell shows none — until the manager starts alignment against PM3. Whole-page manager and aligned scores stay withheld from the assessee unless every cell they are built over is disclosed: a number built over a mix of disclosed and private cells would say something no cell does.
- **Writes.** Either party rates any cell the lens role reads; the pill forwards `as_role`, and `Operations::Assessments::RateSelf` / `RateAsManager` check the level is the lens role's and the role reads the cell (web and MCP share the check — `RatingsController` / `ManagerRatingsController` dispatch the Operations). A manager rating on a cell only the lens role reads stays private until alignment starts against a role that reads it. A cell some started alignment reads is frozen whichever lens the write comes through, and the Operation refuses it with the reason ("Frozen — alignment against PM3 has started", a 403 with a body). The home role's alignment controls render on the record itself, a lens role's on that lens at the level its conversation is about — never on another level of the ladder, where the completion control would count the wrong level.
- **Provenance.** `SelfRated` / `ManagerRated` and their revisions carry `via_role_id` (the lens role, nil on the home role), projected to `self_rated_via_role_id` / `manager_rated_via_role_id`. The feed reads "Self-rated Roadmapping · L2 while exploring PM2". Provenance only — no reader scopes by it (ADR-22).
- **`started` means the record.** A human rating made through a lens (`via_role_id`) on a cell the home role doesn't read is exploration and leaves the participation `enrolled` (`CurrentAssessment#in_home_scope?`). Every other human rating starts it — deciding a rating made on the record by today's bindings would let a rebuild un-start a participation whose capability was archived since.

### The lens in the UI

- **The header chip is the control** (`Views::Assessments::LensControl`, both show views through `HeaderChrome`). A `Kit::Dropdown` listing the ladder of the role being read (the home level marked "your level" / "Alex's level", the current lens `aria-current`), "Back to E3" under a lens, and "Another role…", which opens `Views::Assessments::LensRoleModal` — a GET form with the role select grouped by family (`optgroup`) and a level select the `lens-picker` controller rebuilds on a role change, keeping the ordinal the reader started from. Every entry is a plain link, so a lens survives refresh, Back and sharing. Under a lens the chip wears the exploring tone (sky) and `data-lens="exploring"`.
- **The banner replaces the status pill** (`Views::Assessments::LensBanner`): "Viewing your ratings against **Product Manager · PM3**. Your E3 assessment is unchanged. ← Back to E3" (manager: "Alex's ratings…"). The pill describes the record's lifecycle, which a lens neither reads nor changes; the rating controllers skip its stream under a lens.
- **The page reads the lens.** The H1 (self) and the subtitle (manager) show the lens level's title; the target role's examples render under each expectation; the marked level chip reads **TARGET**, not YOU / CURRENT; a card the record doesn't read wears **"Not in your E3 role"** ("their" for the manager) — a statement about scope, not the rating.
- **The hero speaks conditionally**: "Against PM3 you'd be meeting PM3 expectations." Before a score, a lens that adds capabilities says "2 capabilities are new to this role — rate them to see your score" ("the score" for the manager), and "Continue" never points at a cell a started alignment froze.
- **Entries.** A `:performing` / `:mastering` / `:eligible` hero links to the next level as a lens ("See yourself as E4 →", `data-turbo-frame="_top"`). In the framework explorer's view mode, each role row gives a viewer with an assignment in the framework a "My ratings →" link (`aria-label` "See my ratings against Product Manager") — a `standalone` tree-cluster control, so it stays visible on touch.

### Per-role alignment

Alignment is started, completed and re-opened *against a role* (ADR-22). The home role's alignment is the record's and works as it always did; another role's is a conversation about that role, invisible to every cohort surface.

- **Starting it is the disclosure.** On a lens role the banner tells the manager "Your ratings here are private until you start alignment against PM3" and offers **Start alignment against PM3** — a `Kit::Modal` confirmation (`Views::Assessments::StartLensAlignmentModal`), never `confirm()`, listing what happens: the assessee sees the manager's ratings on the role's capabilities, both parties' ratings there lock (the shared ones included), and cells they already agree on are agreed automatically. Only the recorded reporting manager can start it — never a delegate, never an admin outside the chain.
- **Then the lens is the conversation.** Both parties read that lens in `:alignment`, with its own "Mark alignment complete" control (gated on the role's own current-level cells at the conversation's level) and "Re-open alignment against PM3". The banner says where it stands ("Aligning with Alex against PM3 — …", "Your manager started alignment against PM3 — …", "Alignment against PM3 is complete.").
- **Both parties see it without opening the lens.** `Views::Assessments::LensAlignmentChips` renders **Aligning · PM3** / **Aligned · PM3** beside the home status on the list cards, the home page's assessment card and the assessment header, each linking into the lens (`Assessments::LensAlignments` reads them). The assessee is also notified (`LensAlignmentStartedNotifier`, in-app + Slack); a home start still notifies nobody.
- **The feed names the role.** Alignment milestones against another role read "Manager started alignment against Product Manager · PM3" (from the `AssessmentCycleRoleAlignment` row; home milestones still come from the progress row). An entry about another role — its milestones, or a rating made through its lens on a cell the record doesn't read — carries `data-lens-href`, and clicking it switches the page to that lens when the page in front of the viewer doesn't render its card.
- **Nothing counts it.** The list's Self / Manager chips, the cohort report, calibration and the home page's status all keep reading the home lifecycle (`AssessmentCycleProgress#status`); a lens role's alignment moves none of them.

### Declared exploration

Looking through a lens tells nobody — it writes nothing. **Declaring an exploration is the shared act**: "we've agreed to explore PM3", an intent fact on the person's development stream that both parties see, with a lifecycle (ADR-22, D8).

- **Domain.** `ExplorationStarted { exploration_id, target_role_id, target_level_id, target_level_ordinal, started_by_id, note }` and `ExplorationClosed { exploration_id, closed_by_id, outcome, note }`, `outcome` ∈ `pursue` / `not_now` / `moved`. The aggregate allows one open exploration per target role, refuses the role and level already held, and closes only an open one. It needs an assignment but **no open cycle**: it rates nothing, so D7's open-cycle rule for writes doesn't apply, and it outlives the cycle it was declared in.
- **Not a rating scope.** Ratings through the lens stay facts about cells (D1); the exploration only says someone chose to look, who, and what came of it. It never reaches a cohort surface — the cohort report, calibration, `ReviewableAssignments`, cycle lists and the list's Self / Manager chips don't read it (pinned in `role_lens_leak_test.rb`).
- **Who.** The assessee, their recorded reporting manager or an active rating delegate may declare and close one (`AssessmentPolicy#start_exploration?` / `#close_exploration?`, both `rating_participant?`). A view-only ancestor and an admin outside the chain see it but get no buttons.
- **The banner.** Under a lens that isn't the record, `LensBanner` ends with the exploration line: "Nobody is told you're looking." + **Keep exploring this** (assessee), or "Alex isn't told you're looking." + **Share with Alex** (manager or delegate) — each a root-mounted `Kit::Modal` (`StartExplorationModal`) saying who is told and what is and isn't shared, with an optional note. Once declared: "Exploring PM3 since 3 Oct · started by Alex", the note, and **Stop exploring** (`StopExplorationModal` — the outcome as radios, required, plus a note). One exploration per role, so it shows on every level of the explored role; a vertical exploration (E4 from E3) works the same on the home role's ladder. Both forms carry the lens params and the `submit-guard` controller; the controllers redirect back to the lens with a notice.
- **The list.** `/assessments` gains an **Explorations** section on the person's own list — "Product Manager · PM3", then "4 of 10 rated · started by you · since 3 Oct" (`LevelCoverage`'s vetted self count at the target level in the open cycle; omitted between cycles) — and a team card an **Exploring PM3** chip (`ExplorationChips`, the lens chip's sky tone; not on skip-level cards, matching `assessments_mine`). Both link into the lens. `Assessments::OpenExplorations` reads them.
- **Moving into the target closes it.** A role or level change onto the explored role and level closes the exploration as `moved` (the aggregate, same unit of work), so it never lingers naming the record.
- **Read model.** `assessment_explorations`, written by `CurrentAssessment`, PK = the event-carried `exploration_id` (externally addressed by MCP, so a rebuild reproduces it); a partial unique index mirrors one-open-per-role. The projection broadcasts the sync signal, so the banner and the feed update live.
- **Notified.** The other party, on start and on close (`ExplorationNotifier` → `ExplorationStartedNotifier` / `ExplorationClosedNotifier`; see *Comment notifications* for the delivery model): the assessee's act reaches the manager side (reporting manager + active delegates), the manager side's reaches the assessee (and the reporting manager, when a delegate acted), a close by a move into the role reaches both, and never the actor.
- **MCP.** `assessments_start_exploration` / `assessments_close_exploration` (`:mcp_client`), `assessments_explorations_list` (`:none`); `assessments_mine` carries `explorations: { own:, team: }` (open ones) and `assessments_get` under a lens carries the lens role's open one as `current_exploration`.

### Role-scoped reads (NON-NEGOTIABLE)

Every reader that counts, scores or displays ratings says which role it reads for. `assessment_level_ratings` has no role column, so a query filtered by person, cycle and level alone picks up cells the assessed role doesn't bind — the moment a person rates one, or a framework migration re-keys a rating onto a capability their role has dropped.

- **Build the cells from `Assessments::RoleScope`**: `.for(role_id:, framework_id:)` for one role, `.for_roles` for a cohort, `.for_people(cycle_id:, framework_id:, person_ids:)` for each person's home role (enrollment snapshot, live assignment only before the snapshot existed). `#at_level(ordinal)` narrows it; `#bindings` feeds `PersonDevelopment::Scoring`.
- **Filter with `AssessmentLevelRating.within(scope)`** — one scope, or a `person_id => scope` map for a cohort.
- **Say so when a read spans every role**: `.across_all_roles` for activity history, cross-cycle seeding, and a cell someone already named.
- **The `GrowthOs/RatingsMustBeRoleScoped` cop fails CI** on a chain that does neither. Exempt: record building, a `find_by` naming both `capability_stable_id` and `level_ordinal`, and the `CurrentAssessment` projection.
- **Every reader carries an "ignores ratings outside the assessed role" test** built on `create_out_of_scope_rating` ([testing.md](testing.md)).

## Frequency rating vocabulary

The four rating values share a single palette across every surface — inline pill, level chip, divergent-secondary dot — via `Views::Assessments::FrequencyPalette`. The palette uses a red → yellow → green → blue scale: four **maximally-distinct hues** so adjacent states never blur. This replaced the old red → orange → amber → green ramp, whose middle two (orange "Some" vs amber "Most") were near-indistinguishable on small chips — and unusable in a diagonal split (see *Level chip coloring*). Data values (enum, events, DB, test fixtures) **never** change.

| Enum | Sentence phrase | Compact label | Hue |
|------|----|----|----|
| `none` | Not yet | Not yet | red |
| `some` | Some of the time | Some | yellow |
| `occasional` | Most of the time | Most | green |
| `consistent` | Consistently | Consistently | blue |

The bottom of the scale reads **"Not yet"** on every surface — never "None" or "Never". "None" reads as a verdict ("you never do this") and discourages honest self-rating on a capability a person is still growing into; "Not yet" scores identically but frames the lowest rating as a starting point. Same split as the Feedback / Evidence relabel above: the domain value `none` (events, commands, read models, DB columns, the MCP `frequency` enum) is untouched. The pill, the divergence line and the activity feed all show those two words. Sentences that **compose** the phrase after a verb are the one exception: "rated not yet" means the opposite of what it says, so the chip's accessible name and the live-status announcement use the palette's `spoken` form — "rated not yet demonstrated" (`FrequencyPalette.spoken_for`). Same rule for the calibration distribution summary, which puts the count first ("3 Not yet", not "Not yet 3").

**A rating is against the expectation, never the example.** The `BehaviouralExpectation` is the one thing rated at a cell; role illustrations only help the rater read it. So a rating made while reading another role's examples on a shared cell is the same rating as the home one (see *Role lens*).

Ordering is carried by **chip position** (E1…E8 left→right) and the **text label**, NOT by a single-axis colour gradient — so blue marking the top "Consistently" tier reads as a distinct band rather than "even greener than green". The phrase reads inside the inline pill ("…explains reasoning. **Most of the time**"); the compact label is for tight spaces. The hue backs both pill and level chip so the strip and the inline pill agree pixel-for-pixel.

**Blue is only safe as a rating colour because the keyboard-focus ring and selected-state were moved off blue onto the brand teal (`--color-primary` = `#32c8c8`).** The chip and pill focus rings are `focus-visible:ring-primary`; without that move a blue "Consistently" chip would swallow its own focus ring, and blue already meant "selected" / `:performing`. The remaining blue use to watch when extending this: the hero's `:performing` performance-state accent — a separate surface (hero band, not chips), left as-is.

## Frequency pill (primary rating surface)

The primary rating is recorded via an inline `FrequencyPill` that reads as part of the expectation sentence:

```
Breaks down problems, weighs options, and explains reasoning.  [Most of the time ▾]
```

The pill is a colour-coded button with a chevron. Clicking opens a small popover with the four phrase options + Clear rating; selecting a phrase POSTs through the same controller endpoints the previous segmented selector used. The popover reuses the existing `dropdown` Stimulus controller — same pattern as the comment kebab.

**Frozen variants** render the pill as a static coloured span (no chevron, no popover) when `frozen: true` (`aligning` / `aligned` in self / manager context) or `alignment_locked: true` (`aligned` in alignment context). The sentence still reads correctly because the static pill carries the same colour + phrase.

**Untoggle** lives inside the popover as a "Clear rating" item — controllers detect "POST same frequency back" and clear (same untoggle path as before).

## Secondary perspectives (divergence-only, permission-aware)

A divergent secondary perspective renders as a single line below the pill:

```
○ Self rated: some of the time
```

— a coloured dot from the same palette plus a sentence. Replaces the filled progress bar that used to duplicate the text label.

**Rendering rules:**
- Only perspectives the viewer is permitted to see appear. `MatrixDataBuilder` scrubs manager + aligned frequencies when `context == :self`, so a self-viewer never even receives the data.
- Manager context shows Self.
- Alignment context shows both Self and Manager.
- Within the allowed set, only perspectives that **diverge** from the primary render. If self and primary agree, the row collapses.

The wrapper carries a stable id `secondaries-<stable>-<ordinal>` so rating controllers `turbo_stream.replace` it on every rating change — the divergent set grows / shrinks as the primary moves.

## Level chip coloring

The chip fill is the **rating language**; small corner glyphs (below) are a separate **content language**. The two never share a visual primitive.

| Level position | Frequency | Background |
|---|---|---|
| Below person_level | Unrated | Mid blue `blue-300` (assumed consistent — "Consistently" is blue, so a clearly-blue tint reads as consistent at a glance; kept a shade lighter than the solid `blue-500` of an explicit "Consistently" so the two stay distinguishable. An earlier near-invisible `blue-100/60` wash failed to register as a rating) |
| Below person_level | rated | Solid hue from the palette (red / yellow / green / blue) |
| At/above person_level | Unrated | Neutral gray |
| At/above person_level | rated | Solid hue from the palette — same fill regardless of level position |

**Rated chip fills are the exact `-500` (light) / `-400` (dark) shades the `FrequencyPalette` dots use everywhere else.** Same hue at the same saturation across pill / chip / divergence — the four ratings read as four distinct, equally-intense colours rather than four muddy near-identical tints. Text on rated chips uses `text-{hue}-950` in both modes for ~7–10:1 contrast against the saturated fill (WCAG AA on small text needs 4.5:1; lighter text tokens fail it on `yellow-500` / `green-500`).

### Misalignment → diagonal split (replaces the divergence dot)

When two perspectives the viewer can see **disagree**, the chip paints a **diagonal split** instead of a solid fill: a `/` seam from bottom-left to top-right, with the **viewer's own perspective in the top-left triangle** and the other party's bottom-right. **Position tracks the viewer, not a fixed self/manager assignment** — so a viewer always finds their own rating in the same corner, and the split reads identically across surfaces (NON-NEGOTIABLE: keep the two in sync). Concretely: the **manager** (or an active rating delegate) sees **their own rating top-left** in both the manager view and their alignment view; the **assessee** sees **their own (self) rating top-left** in their alignment view. So the manager view and the manager's alignment view are identical, and the assessee's alignment view is the mirror. The signal is threaded as `viewer_is_manager:` (true for the manager-side party) from the controller / page view down to `LevelChip` — `:manager` context is treated as manager-side by definition, and `:self` never splits, so the flag is only consulted in `:alignment`. Implemented as a base fill (the bottom-right colour) plus an absolute clip-path overlay (the top-left colour); the centered level code gets an opaque backing so it stays legible across the seam. A `data-split="true"` hook on the overlay supports testing.

> **Earlier design (superseded):** the corner used to track the context's *primary* perspective (manager view → manager top-left; alignment → self top-left, "reading order"). Because "primary" changes meaning between contexts, the two corners swapped between the manager view and the manager's alignment view — the ratings appeared to jump sides. Tying position to the viewer fixes it.

- **Why a split, not a coloured dot:** the *seam itself* is a shape signal — a split chip reads as "contested" regardless of the two colours, so it survives colour-blindness and the colours-too-close trap. It also shows *both values* in place.
- **Partial ratings split too:** when one perspective has rated and the other hasn't, the chip splits the rated colour against the missing slice — so "I rated, they haven't" doesn't masquerade as a mutual solid fill. The missing slice's colour depends on level: **at/above** the person's level it paints **grey** (genuinely unrated); **below** the person's level it paints the **assumed-consistent blue** (`blue-300`), the same default the solo chip and scoring use for a below-level cell, rather than grey — a grey slice there would wrongly read as "no rating" when the system in fact assumes consistency. The assumed default only fills a slice whose *counterpart was rated*; a below-level cell with neither perspective rated stays the lighter solo `blue-300` tint via the unrated branch. Crucially, an explicit `consistent` (solid `blue-500`) still **splits** against an assumed-consistent default (`blue-300`) — the two agree on the value but differ in explicit-vs-assumed, so both blue shades show in their perspective positions rather than collapsing to one fill. The chip renders solid only when both slices are *explicitly* rated and equal (or in a single-perspective context).
- **Per context:** `:self` never splits (only one perspective visible). `:manager` splits on self-vs-manager. `:alignment` splits on self-vs-manager **until a recorded aligned value resolves the cell to a solid** — so a contested cell visibly snaps solid as you record agreement (this also fixed the old "both rated but the chip is grey" bug, since the aligned value was empty pre-resolution). **Post-completion (`alignment_locked`), a residual split renders muted** (`opacity-60`, aria note "not reconciled during alignment"): a split's semantic is "contested — reconcile this", a call to action nobody can act on once everything is frozen, so it demotes to history. Only off-current-level cells can carry one — the completion gate (see *Lifecycle*) guarantees every current-level cell is solid.

### Evidence / comment → corner glyphs (replaces the slate/violet dots)

Content indicators live in the chip's **bottom-right corner as glyphs** — a **paperclip** (evidence) and a **speech bubble** (comment), on one muted backing pill (`text-gray-600`, `data-glyph="evidence"` / `data-glyph="comment"`). They stay on the chips (not the expansion) so "which levels have backing" is visible *before* drilling in. Glyphs not dots: a shape says what it is without a colour legend and can't be confused with the frequency-colour fill.

**The green rated-check ✓ was retired** — it read as "aligned" (it only ever meant "rated"), and the fill already encodes rated-vs-unrated. Full per-perspective values live in the expansion panel's `SecondaryRatingLine`s.

## Multi-perspective scoring

`Assessments::MatrixDataBuilder` builds four parallel scoring outputs:

| Key | Perspective | Frequency Used |
|---|---|---|
| `scoring` | `:effective` (default) | Fallback chain: aligned → manager → self |
| `self_scoring` | `:self_only` | Only `self_rated_frequency` |
| `manager_scoring` | `:manager_only` | Only `manager_rated_frequency` |
| `aligned_scoring` | `:aligned_only` | Only `aligned_frequency` |

Each uses `PersonDevelopment::Scoring` with a different `perspective:` parameter. Returns `nil` (not empty hash) when no ratings exist for that perspective — `HeroSummary` falls back to effective when its preferred perspective is nil.

Every perspective hash now carries a `performance_state` symbol (see [scoring-model.md](../architecture/scoring-model.md)) and, when the person isn't at the top of the level ladder, a `capability_scores_at_next_level` map keyed by stable_id — each capability's own score at the level above, from the engine's `capability_scores_at`. The hero's middle band uses both to pick its narrative — see *State-driven panel* above.

## Evidence-link valence — "what does this say about the behaviour?"

Every evidence link carries a **valence** — the linker's judgment of what the
evidence says about the behaviour at that capability × level — on a 4-point
forced-choice scale (no neutral midpoint, mirroring the frequency vocabulary):

| Event value (frozen forever) | UI label (changeable) |
|---|---|
| `strongly_demonstrated` | Strongly demonstrates |
| `demonstrated` | Demonstrates |
| `growth_area` | Growth area |
| `significant_growth_area` | Significant growth area |

Design rules — all deliberate, don't relitigate piecemeal:

- **Valence lives on the LINK, not the item.** One piece of feedback can be
  positive evidence for one behaviour and constructive for another.
  `EvidenceLink.valence` is asserted by whoever creates that link
  (`linked_by_id`) — including a non-author link editor.
- **Required on every NEW link; never retro-forced.** The aggregate
  (`record_evidence` / `add_evidence_link`), the Operations, and the modal's
  `required` controls all demand it. Links created before valence existed stay
  nil forever (events are immutable; intent can't be backfilled) and pass
  through content edits untouched — no backfill-by-attrition. Reclassifying is
  an explicit affordance (the link row's select in the edit modal / the
  `assessments_set_evidence_link_valence` tool) emitting
  `EvidenceLinkRevalenced`: link identity and `linked_at` preserved, no
  `edited_at` bump, silent no-op when unchanged.
- **NOT a scoring input.** ADR-10 stands: valence is narrative metadata for
  the rater and the alignment conversation. Nothing in
  `PersonDevelopment::Scoring` reads it, and nothing should without an ADR.
- **Surface vocabulary** lives in `Views::Evidence::Valence` (labels + badge
  classes). Badges use emerald / amber / rose tints — never the frequency
  palette (red/yellow/green/blue means *ratings*) — and the text label is
  always present; colour is reinforcement, never the sole signal. Badges
  render per-cell on the expansion panel's evidence cards (the same item can
  read "Demonstrates" in one cell and "Growth area" in another, via the
  transient `EvidenceItem#link_valences` map) and on the hub response cards'
  "Applies to" chips.
- **Modal UX**: one shared valence dropdown (`ModalForm#valence_select`;
  surface term is "valence", never "judgment"), rendered per **"Applies to"
  row** — every linked behaviour carries its own (see *The unified "Applies
  to" block* below). The block sits after "What happened?" (hierarchy: what
  happened, then what it says, per behaviour; deliberately no default). On
  :new/:respond the seeded origin row's valence is **required** (id
  `evm-valence`); JS-staged rows carry their own required select (blank
  "Valence…" placeholder blocks submit until chosen — mandatory for every
  new link without overloading the add). In edit mode a pre-valence (nil)
  link renders an optional "Valence…" placeholder; a classified link can be
  re-classified but not cleared. Per-link valences submit as
  `evidence[link_valences][<cap>|<level>]` alongside the untouched
  `desired_links[]` tokens; `EvidenceDiffSubmit` validates every new link's
  valence BEFORE any write, then derives add-with-valence / revalence
  deltas from the map.
- **Feed coverage**: `evidence_linked` entries carry the valence label on the
  secondary line; reclassifications are their own `evidence_revalenced` kind
  ("Growth area (was Demonstrates)"), evidence group, anchored to the cell.
- **MCP parity**: `assessments_record_evidence` /
  `assessments_add_evidence_link` / `assessments_respond_to_evidence_request`
  take a required `valence` enum (each `additional_links` entry carries its
  own); `assessments_set_evidence_link_valence` reclassifies. Read payloads
  include `valence` per link (nil = pre-valence link).

## Evidence-linkage discussion threads

Every evidence **linkage** — one (evidence_id × capability_stable_id ×
level_ordinal) cell an item is linked to — carries its own discussion
thread, so the manager and assessee can debate *that linkage and its
valence* rather than the item in general. Design rules, all deliberate:

- **Anchored to the linkage's natural key, not the `EvidenceLink` row.**
  The thread survives valence reclassification (the discussion usually
  *causes* it), link removal, and re-add (same key ⇒ the history
  reattaches). Data model: `commentable_type: "evidence_link"` on
  `PersonDevelopmentComment` + an `evidence_id` column — same events,
  projection (`CommentThread`), threading model, and `comments-thread`
  Stimulus contract as cell comments; comment rows reuse
  `Views::Assessments::Comments::Card` verbatim.
- **Surface**: a collapsed count-plus-excerpt disclosure on each evidence
  card (per cell — the same item carries an independent thread in every
  cell it's linked to). A native `<details>` hosts a `loading: "lazy"`
  turbo frame, so the thread is fetched only when opened.
- **Lifecycle rows interleave with comments.** The thread renders the
  linkage's story — *linked as «valence»*, *valence changed*, *removed*,
  *withdrawn* — as muted system rows (hollow dot, italic, no kebab/reply)
  read from the PD stream by `Assessments::EvidenceLinkThreadQuery`
  (stream reads stay off the matrix render path; only the lazy frame
  pays them).
- **Removal keeps the thread open**: the removal is often the
  discussion's outcome, so the composer stays under a "no longer linked"
  notice (the aggregate accepts any linkage that *ever* existed).
  **Withdrawal makes it read-only** (the artifact itself is retracted;
  aggregate-enforced). Both removal surfaces (card kebab unlink confirm,
  modal "Applies to" row) disclose an active thread's comment count and
  that it is preserved.
- **Participants = the assessment-side comment set** (assessee + manager
  chain + active delegate + tenant admin — `PersonDevelopmentCommentPolicy`
  verbatim). The **evidence author (a peer) is deliberately excluded**;
  the hub deliberately shows no thread counts so it doesn't tease a
  conversation the author can't open. No pre-alignment gate beyond what
  cell comments already accept.
- **Feed**: posts surface as `evidence_link_commented` entries (comments
  chip, cell-anchored, naming whose feedback is discussed); linkage
  comments also count toward the level chip's comment glyph. Live via
  `CommentThread`'s existing broadcast.
- **Writes** go through the same comments endpoints
  (`Assessments::CommentsController`; `comment[evidence_id]` selects the
  type) with frame-scoped redirects; MCP parity via an `evidence_id`
  param on `assessments_post_comment` / `assessments_comments_list`.

## The unified "Applies to" block (evidence modal)

The modal used to treat the "primary" linkage (a top context card + its own
valence field) and the "Also applies to" extras as two separate surfaces —
disorienting when Edit was opened from a *secondary* cell, because the card
at the top named a different behaviour than the one clicked. The linkage UI
is now **one "Applies to" block**: every behaviour the feedback is linked to
renders as a uniform row — capability · level (with the role's level title),
the behavioural expectation, that link's valence dropdown, and a collapsible
**Examples** disclosure (role illustrations) — plus the capability/level
picker at the block's foot.

Rules — all deliberate:

- **The origin cell is a creation fact, not a protected link.** The
  `record_evidence` origin (`EvidenceItem.capability_stable_id`/`level_ordinal`)
  stays immutable event history, but the UI never singles it out: in edit
  mode ALL active links render as removable rows, the origin included (the
  aggregate already allowed removing it — the only invariant is "an active
  item keeps ≥ 1 link"). The edit form submits **no `primary_cell`**;
  `EvidenceDiffSubmit#diff_edit` diffs desired vs current links. Removing
  the last remaining row is locked client-side (× disabled, "withdraw it
  instead") with the aggregate as backstop.
- **The entry point orients the modal.** The card's Edit trigger passes the
  cell it sits in (`capability_stable_id` + `level_ordinal` params); that
  row sorts first, gets a primary ring + tooltip ("You opened this feedback
  from here"), and its Examples render pre-expanded. Hub-opened edits carry
  no entry cell — rows keep `linked_at` order.
- **:new / :respond seed the block** with a fixed (non-removable) origin row
  carrying the REQUIRED valence — it anchors `record_evidence` / the
  request's cell, so `evidence[primary_cell]` still submits in these modes.
  These two modes also keep a **writing-prompt card** above the content
  fields (capability · level, "What good looks like", examples behind a
  disclosure) — when composing, the behaviour being written about belongs
  above the textarea. Edit mode renders no top card; hub-opened edits get a
  one-line "Feedback on ⟨name⟩'s assessment · ⟨role⟩" scope line instead
  (the hub lists items across people).
- **Examples come from the embedded map.** `FrameworkCellOptions#expectation_map`
  carries role-scoped `illustrations` per valid cell, so server-rendered and
  JS-staged rows render the same disclosure without extra fetches.

## Requesting evidence (cell-scoped)

A manager (or the assessee, or an active rating delegate, or a tenant admin —
`EvidenceRequestPolicy#request?`) can **ask a colleague for evidence on a specific
capability × level**. The whole flow is cell-scoped: it originates from a cell and
the response lands pre-linked to it.

- **Entry point** — a per-cell **"Request evidence"** button on the capability-card
  expansion ([capability_card_expansion.rb](../../app/views/assessments/capability_card_expansion.rb),
  `#request_evidence_section`), next to "Add evidence". Gated on
  `can_request_evidence`, threaded from `AssessmentsController#viewer_can_request_evidence?`
  through the card view chain exactly like `can_create_evidence`.
- **The modal** ([Views::Evidence::RequestForm](../../app/views/evidence/request_form.rb),
  hosted once via [RequestModalShell](../../app/views/evidence/request_modal_shell.rb))
  carries the cell context (capability · level + behavioural expectation, via
  `CellContextResolver`), a **debounced name/email search**, the **assessee's
  org-neighbour suggestions** (manager, peers, direct reports — `Assessments::RequestCandidates`),
  a **multi-select** chip list, **one shared reason**, and an optional due date.
- **Search + suggestions** are server-rendered: the search input (debounced ~250ms by
  [request_evidence_controller.js](../../app/javascript/controllers/request_evidence_controller.js)
  — now a thin subclass of the shared
  [person_picker_controller.js](../../app/javascript/controllers/person_picker_controller.js),
  the reusable typeahead+chips control this picker was extracted into; the
  calibration participant picker reuses it via
  [Views::Shared::PersonPicker](../../app/views/shared/person_picker.rb))
  repoints the `#request-candidates` frame
  ([RequestCandidatesFrame](../../app/views/evidence/request_candidates_frame.rb));
  selection is client-side (chips + `requestee_ids[]` hidden inputs). People with a
  **pending request on the cell are greyed "Asked"** and can't be re-selected.
  The **assessee themselves is a valid recipient** (surfaced as the first
  suggestion, relation `assessee`) — a manager can nudge their report for more
  evidence; only the **requester** (you) is excluded (asking yourself is
  meaningless). The aggregate + operation enforce the same "not yourself" rule.
- **Two render endpoints** (`EvidenceRequestsController#modal` / `#candidates`,
  assignment-scoped, `EvidenceRequestPolicy#request?`-authorized) feed the lazy modal
  frame and the typeahead frame.
- **Multi-send** — `POST /evidence_requests` loops the single-recipient
  `Operations::Assessments::RequestEvidence` once per `requestee_ids[]` entry (shared
  message + due), flashing a per-batch summary ("Sent to N people · Skipped M"). MCP
  parity is preserved — the op is unchanged; multi-send is a web convenience.
- **Visibility is disclosed to the requestee** before they write a word: the open
  incoming hub card and the respond modal both state the response will be visible
  to the assessee, their managers, and workspace admins (the `EvidencePolicy` view
  rules). Skipped when the requestee IS the assessee. Keep the copy in the two
  surfaces (`HubView#response_visibility_note` / `ModalForm#visibility_note`) in
  step with the policy if view rules ever change.

**Two modal overlays, one `modal` controller.** The assessment screen now hosts both
the evidence modal and the request modal under the wrapper's single `modal`
controller, so **every** evidence/request trigger names its overlay via
`data-modal-target-id` (`evidence-modal-overlay` / `evidence-request-modal-overlay`) —
framework-explorer Hard-Won Lesson 19.

### Reminders and nudges on open requests

An unanswered request doesn't rely on the requestee's memory:

- **Automatic reminders** — the hourly `EvidenceRequestReminderSweepJob` emits
  `EvidenceRequestReminderSent` (kinds `no_response` after 7 quiet days /
  `due_soon` 2 days before the optional due date, whichever comes first; each
  automatic kind at most once, aggregate-guarded). Timing policy — incl. the
  24h floor, 3-day gap, and 30-day rollout cap — lives on
  [`EvidenceRequest`](../../app/read_models/evidence_request.rb); events carry
  `acting_via: "system"` provenance.
- **Manual nudges** — the requester (or a tenant admin) can chase an open
  request via `Operations::Assessments::NudgeEvidenceRequest`
  (`POST /evidence_requests/:id/nudge` on the web,
  `assessments_nudge_evidence_request` over MCP), repeatable once
  `EvidenceRequest::NUDGE_GAP` (2 days) has passed since the last reminder of
  any kind. Automatic reminders and manual nudges share one clock — a nudge
  defers the sweep and vice versa.
- **Delivery** rides the notification chain: `evidence_request_reminder`
  Noticed type (in-app + Slack default, email deferred) with kind-aware copy;
  the manual copy names the nudger. The async handler drops the nudge if the
  request resolved before the job ran.
- **History** — every reminder is appended to the projected
  `reminder_history` (kind, at, by_id) and stamps `last_reminded_at`, both
  replay-safe. The hub renders the history on every open card and sorts open
  lists stalest-first (`least_recently_touched`).

**Resolution notifications carry the response.** The requester's "answered" /
"declined" notification (in-app + Slack) quotes the response itself — the
evidence content, or the decline reason — excerpted at
`ApplicationNotifier::EXCERPT_LIMIT` (280 chars, shared `quoted_excerpt`
helper) so the Slack DM reads the feedback without a round trip to the hub;
the deep link still lands on the hub card for the full text.

### Assessment-cycle feedback reporting

The cycle's **Feedback & evidence** report counts feedback provision separately
from request workflow:

- `feedback_provided` is every unique active `EvidenceItem` attributed to the
  cycle, including proactive feedback. Multiple `EvidenceLink` rows never
  multiply the count.
- `provided_by_request` is the subset recorded in response to a cycle request;
  proactive feedback is the remainder, exposed by the compatibility field
  `provided_unsolicited = feedback_provided - provided_by_request`.
- Withdrawn items are excluded from active provision and reported separately.
- A relink, migration, or valence change never changes the item's original
  cycle. Prior-cycle evidence reused in this cycle is not newly provided.
- If existing evidence fulfils a new request, the request is fulfilled but the
  item is not counted as new feedback.
- Active feedback is also grouped by immutable provider-to-recipient direction:
  manager → report, peer → peer, or report → manager. Self feedback is separate
  and requested versus proactive remains an orthogonal split.

`EvidenceRequested` and `EvidenceRecorded` carry nullable `cycle_id`. Direct
feedback and requests use the PersonDevelopment aggregate's current cycle; a
response explicitly inherits its request's cycle so a late response remains
with the original cycle after close. The projections copy this value without a
`CODE_VERSION` bump. Historical null rows are inferred at report time only when
one enrollment window matches; ambiguous records stay unattributed.

New `EvidenceRecorded` events also carry nullable `feedback_direction`, captured
from the provider and recipient's relationship at write time. Historical
`source: manager` and `source: self` rows retain exact manager → report and self
classification. Historical `source: peer` rows cannot be split reliably, so the
report labels them `Peer → peer or report → manager (historical)` and omits that
row once its count reaches zero. Replays leave the new column null for old
events, so this additive field also needs no projection `CODE_VERSION` bump.

The report is aggregate-only: no contributor identity, content, evidence title,
or individual request row. Managers see their `Person#all_reports` subtree;
admins/HR see the whole cycle and can switch to My org. Web and MCP share
`Operations::Reporting::EvidenceCoverage`.

Either surface can narrow the report to **one calendar month** of the cycle
(`month: "YYYY-MM"` over MCP; a Month select + Apply on the web — a plain GET
form, deliberately not submit-on-change). The month counts feedback by
`recorded_at` and requests by `requested_at`, inside the cycle attribution
above; request statuses stay current, so the two card families use different
windows (see [reporting.md §4.9](../architecture/reporting.md)). Boundaries are
UTC (`Time.zone`) until tenants carry a zone. `Reporting::CycleMonth` owns the
key format, the label, and the months list that both the select and the MCP
payload's `available_months` render.

**Hub layout** ([hub_view.rb](../../app/views/evidence/hub_view.rb)): "Open
requests" (subsections *Asked of you* / *Your requests*, stalest first, with
history + respond/decline or nudge/cancel actions) → "Completed requests"
(subsections *Asked of you* / *Your requests* / *Feedback / Evidence you've
provided* — the viewer's authored evidence, edit/withdraw). Every evidence
item on the hub (authored cards + embedded responses) carries a **"View in
assessment"** deep link to its **first active linkage**
(`?capability=` + `?level_ordinal=` — focuses and scrolls the card) so the
feedback can be read in situ; the controller renders it only when
`AssessmentPolicy#show?` admits the viewer, so a peer who provided feedback on
a colleague's assessment gets no dead link.

**Decline stays out of the way of the reply.** On an incoming card, "Decline
request" is a secondary button beside the primary "Provide feedback / evidence"
button, and it opens its own modal with a labelled, multi-line reason field and
a note that the requester will see it. An always-open reason box under the
reply button read as the reply box: a requestee wrote their feedback into it
([#476](https://github.com/mr-yum/growth-os/issues/476)). The reply itself is
written only in the evidence modal.

## Comment notifications

Every posted assessment comment — cell thread or evidence-linkage thread —
notifies the conversation's other parties via
[`PersonDevelopment::AsyncHandlers::CommentNotifier`](../../app/contexts/person_development/async_handlers/comment_notifier.rb)
(async RES handler on `CommentPosted`; NOT a projection — replaying would
re-send). Three rules, deduped, the author always excluded, one notification
per recipient per comment (a recipient matching several rules gets the most
specific — reply beats the generic kinds):

| Rule | Recipient | `NotificationType` |
|---|---|---|
| Reply | The parent comment's author | `comment_reply` |
| Comment by anyone ≠ assessee | The assessee | `assessment_commented` |
| Comment by the assessee | The **recorded reporting manager** (live `Person.manager_id` fallback) **+ active rating delegates** | `team_assessment_commented` |

Edits and deletes stay silent (the thread shows them). Skip-level ancestors
and tenant admins can read threads but get no pings — observers, not parties.
Recipients are by construction inside the comment-visibility set; the peer
evidence author is excluded from linkage threads upstream, so no leak is
possible. Bodies use `quoted_excerpt` with a context line ("«evidence
author»'s feedback · «Capability» · L«n»"); the deep link carries the
existing `?capability=` + `?level_ordinal=` focus params, and one URL serves
both parties (the show route renders per-viewer context).

**Delivery is in-app-first everywhere**: external channels (Slack) fire only
if the recipient hasn't read the in-app copy within
`ApplicationNotifier::ESCALATION_DELAY` (1 minute) — the smart-escalation
rules in [`ApplicationNotifier`](../../app/notifiers/application_notifier.rb),
shared by every notification type. The **first Slack DM a user ever
receives** carries a one-time footer disclosing this model and linking
`/settings/notifications` (a persisted fact —
`User#external_notifications_disclosed_at`, marked only after a successful
post — see [`SlackDeliveryMethod`](../../app/notifiers/slack_delivery_method.rb));
the notification bell's dropdown links the same page persistently via a gear
icon.

## Activity feed coverage (NON-NEGOTIABLE)

**Every action a user can take on the assessment screen MUST produce a
representation in the activity feed.** The feed is the assessment's audit
trail and shared narrative — if an action changes assessment state but leaves
no entry, the other party (and the actor on reload) silently loses the story.

> **Actionable entries.** When an assessment feed entry should let the viewer
> *act* on it inline (the way the framework feed lets a reviewer approve a
> pending suggestion), follow the **"actionable feed entry" pattern** documented
> in [framework-explorer.md §12](framework-explorer.md): actionable iff
> `pending? && viewer-authorised` (server-computed), primary action inline +
> needs-input/destructive via a root-mounted modal, every action through an
> `Operations::*` class, 204 responses, and a live resolution that refreshes
> every affected frame. Don't reinvent it.

This applies to ratings (self / manager / aligned + their revisions/clears),
alignment milestones, **declared explorations** (`exploration_started` /
`exploration_closed` — alignment group, framework-level, the note as the
secondary line, clicking switches to the explored lens, visible to anyone who
sees the whole assessment), comments, and **all evidence actions** — recording,
editing, withdrawing, **and link add / remove** (`evidence_linked` /
`evidence_unlinked`). It also covers actions that originate OFF the
assessment screen but land on the person's stream: a calibration session's
**rating-revisit request** surfaces as `rating_revisit_requested` (ratings
chip, cell-anchored, the room's note as the secondary line), gated by the
same manager-rating privacy rule as `MANAGER_KINDS` — value-free by design,
and resolved implicitly when the manager rating for that cell changes
(no resolution entry; see
[calibration-sessions.md](../architecture/calibration-sessions.md)). The
rater is also **notified** (`rating_revisit_requested` Noticed type via the
async `RatingRevisitNotifier` — in-app-first + Slack escalation, dropped if
the rating already changed by delivery time, never a self-ping). When
you add a new assessment action, you add its feed entry in the same change:

1. **Source the entry.** Entries come from either the RES stream
   (`Assessments::ActivityFeedQuery#stream_events`, e.g. rating / relink /
   `EvidenceLinkAdded` / `EvidenceLinkRemoved` events) or a read model
   (`EvidenceItem`, `PersonDevelopmentComment`, `AssessmentCycleProgress`).
   Prefer the stream when the action is an event with no standalone read-model
   row (link add/remove are events on the existing item, so they're read from
   the stream like relinks).
2. **Add the `_entries` method** to `ActivityFeedQuery` and include it in
   `#call`. Anchor the `Entry` to the affected `(capability_stable_id,
   level_ordinal)` so per-cell focus filtering surfaces it; honour the same
   author/visibility gate as neighbouring entries (peers see only their own).
3. **Register the kind** in `Views::Assessments::Activity::Entry` — `KIND_DOT`
   (colour), `KIND_GROUP` (which filter chip: `ratings` / `evidence` /
   `comments` / `alignment` / `authority`), and `#summary_text` /
   `#secondary_text`.
4. **Broadcast the sync signal** from the projection that materialises the
   action so the feed updates in **real time** (see below).
5. **Cover it** in `test/queries/assessments/activity_feed_query_test.rb`
   (entry emitted, anchored to the right cell, visibility-gated) and assert
   the `KIND_GROUP` so it lands under the intended filter.

A new action with no feed entry is an incomplete feature, not a follow-up.

### Real-time is part of coverage (NON-NEGOTIABLE)

The activity feed must update **live for everyone — including the user who
took the action**. The mechanism: the projection that writes the action's
read model / handles its event calls `broadcast_assessment_sync(event)`,
which nudges the `#assessment-sync-signal`; `assessment_sync_controller`
then reloads the activity frame. Crucially, the activity frame reload is
**exempt from the actor's self-suppression window** — the suppression only
skips the matrix/scoring re-fetch (which would flicker and reset scroll),
never the activity frame — so the actor sees their own entry appear too.

Therefore **every projection that handles an on-screen assessment action
MUST call `broadcast_assessment_sync` in its `call`** (guarded by
`Projections::Replayer.replay_mode?` so rebuilds stay silent). Today that is
`CurrentAssessment` (ratings / alignment / explorations), `EvidenceCollection` (evidence +
links), `CommentThread` (comments), and `AssessmentAuthority` (delegation
grant/revoke, reporting-manager). When you add a projection for a new
assessment action, add the same broadcast — a feed entry that only appears
on the next manual reload does not satisfy this rule.

## Real-Time Sync

Rating changes by another viewer are broadcast via ActionCable. `assessment_sync_controller` observes a signal element for Turbo Stream replacements and triggers a frame reload:

```
ActionCable broadcast → Turbo Stream replaces #assessment-sync-signal
  → MutationObserver fires → reload matrix + scoring + activity frames
    → turbo:frame-load → update performance pct badge
```

**The acting user's rating changes are announced non-visually** (WCAG
4.1.3, audit issue #318): both show views render a pre-existing polite
live region (`#assessment-live-status`, `role="status"`, sr-only, outside
every frame), and each rating Turbo Stream response — self / manager /
alignment, rate or clear — updates it with server-rendered copy via
`Assessments::TurboStreamHelpers#live_status_stream` ("Rated most of the
time — Critical Thinking, E1"). Broadcasts never touch the region, so
only the actor hears their own confirmation.

**The rater's own broadcast echo is suppressed.** `assessment_sync_controller#listenForOwnSubmits` arms a 5-second `_suppressReloadUntil` window on the EARLIEST signal of a user-initiated form submit — `pointerdown` / `mousedown` / `click` (capture phase) against any real submit control (`button[type='submit']`, default-type `<button>` inside a form, `input[type='submit']`), plus `turbo:submit-start` as a backstop for programmatic submits. The MutationObserver bails when within the window so the rater's own broadcast doesn't trigger a redundant frame reload (flicker + scroll reset).

**Focus-param merge on reload.** `#mergeFocusParams` reads `?capability=` + `?level_ordinal=` **and the whole `levels[<stable_id>]` map** from the BROWSER URL and stamps them onto the matrix frame's `src` before reload, so both the focused cell AND every card's per-capability selected level survive broadcast-driven frame reloads (the map is replaced wholesale from the browser URL, the source of truth kept current by `matrix_controller` on every chip click).

## Stimulus controllers

| Controller | Responsibility |
|---|---|
| `matrix_controller.js` | Chip-click focus, card-header click focus (capability), scroll-driven capability focus via IntersectionObserver, smooth-scroll-under-sticky-headers, URL sync (`?capability=` + `?level_ordinal=` for focus; accumulating `levels[<stable_id>]` map for per-capability rendered level), URL-first focus restoration on connect, `data-focused` stamping on cards, sibling card dimming when a card is URL-focused. Shared with the framework explorer (table-mode methods live there). |
| `category_nav_controller.js` | Publishes `--sticky-header-h` via `getBoundingClientRect().height` + `Math.ceil` + `ResizeObserver`. Smooth-scrolls to category sections on chip click. Updates the active chip on scroll (suppressed for 900ms after a chip click — see *Category navigation*). |
| `assessment_sync_controller.js` | ActionCable sync, self-submit suppression window, dual-frame reload, focus-param and lens-param (`as_role` / `as_level`) merge before reload. |
| `lens_picker_controller.js` | The "Another role…" dialog: rebuilds the level select from the chosen role's levels, keeping the reader's ordinal (nearest, lower on a tie — the same rule as `Assessments::Lens`). |
| `activity_feed_controller.js` | Listens for `matrix:focus-changed` and narrows entries by capability + level focus. An entry about another role (`data-lens-href`) switches the page to that lens when its card isn't on the page. |
| `activity_pane_controller.js` | Opens and closes the activity sidebar (inline on lg+, a fixed overlay below), with its cookie and `?activity=` URL state. With `fitViewport` (both assessment show views) it caps the pane's height on lg+ at the room below the pane's own top, re-measured on scroll, resize and body resize, so the feed's last entries stay on screen — see Hard-Won Lesson 19. |
| `context_pane_controller.js` (shared with framework explorer) | Right-pane suggestion / activity panel state, URL focus sync. |
| `continue_assessing_controller.js` | Bottom-line CTA — dispatches a window event with the next-unrated capability stable_id + level, picked up by `matrix_controller#focusUnrated`. |
| `modal_controller.js` | Generic `Kit::Modal` controller — open/close, body-scroll-lock. **Outside-click dismissal is opt-in** (`dismissOnOutsideClick` value, default off) so a stray background click can't discard a half-filled transactional form — modals close via the × button, Cancel, Esc, or a successful submit. **Esc routes through `modal#escape`**: an overlay opting in via `data-modal-dirty-guard="<message>"` confirms before an Esc discards typed input (audit issue #315 — the evidence and request-evidence overlays opt in); × and Cancel stay immediate as explicit dismissals. **Keyboard focus follows the APG dialog contract** (audit issue #317): on open, focus moves into the dialog — the panel (`tabindex="-1"`) while a lazy frame loads, then the first field on `turbo:frame-load`; Tab/Shift+Tab wrap within the open overlay; on close, focus returns to the invoker, falling back to the ancestor dropdown's kebab when the invoking menu item is hidden. Hosts the Delegates modal (standalone) and the unified evidence modal (embedded — a lazy `#evidence-modal` frame). |
| `submit_guard_controller.js` | Keeps one user action to one request (audit issue #335) by blocking a **re-entrant submit** — and nothing else. Mounted on a Turbo form, it flips a flag on `turbo:submit-start` / `turbo:submit-end` and stops any `submit` fired in between, on the form, ahead of Turbo's document-level listener — so a programmatic `requestSubmit()` can't slip past the disabled button. The in-flight *treatment* is Turbo's own: `config.forms.submitter` (default `"disabled"`) disables the submitter and `data-turbo-submits-with="Saving…"` swaps its label, both restored on `requestFinished` whatever the outcome (a validation error keeps the modal open for another attempt). Hand-rolling those here leaked a pinned `min-width` and stuck the label on a same-task double submit. Known edge: two submits in the same task both precede `turbo:submit-start`, so the guard arms from the second task onward — Turbo's navigator aborts the first submission there, so one request still lands. Mounted on the evidence modal form **and the request-evidence send form** — that one matters more: `Operations::Assessments::RequestEvidence` mints a fresh `request_id` per POST, so unlike the idempotency-harmless evidence save, a second submission that lands creates duplicate requests and duplicate notifications for every recipient. |
| `submit_fallback_controller.js` | Surfaces transport-level Turbo submit failures that are otherwise silent (audit issue #316). Claims non-stream error responses at `turbo:before-fetch-response` (form submissions only — frame-load failures belong to `frame-error`) so a 5xx HTML body is never rendered as the page, and injects a retryable message into a pre-existing `role="alert"` region (`Kit::SubmitFallbackMessage`) — connection copy for transport/5xx, reload copy for 4xx rejections. Domain errors (turbo-stream responses) stay with the server's own rendering. Mounted on the rating pill wrapper, the evidence modal panel, and the request-evidence modal panel — in each case the live region sits OUTSIDE the lazy frame, so it survives a frame swap. |
| `frame_error_controller.js` | Gives a **lazy turbo-frame's failed load** a voice (audit issues #328 / #365) — one instance per frame, mounted on an element wrapping that frame and its `Kit::FrameLoadError` block. **Mounting is a bare `data-controller="frame-error"` plus the two targets**: the five listeners bind themselves in `connect()` and unbind in `disconnect()`, rather than being declared as a hand-copied `data-action` string per site where one missed line would silently drop one failure shape. Three failure shapes, all verified against turbo-rails 2.0.23: `turbo:fetch-request-error` (network dropped), `turbo:frame-missing` (a response with no matching frame — **cancelled**, since its default renders Turbo's own "Content missing" into the frame and then throws; it does NOT navigate), and `turbo:before-fetch-response` → `responseReceived` (`FetchResponse#responseHTML` resolves undefined for a non-HTML body, so `loadResponse` renders nothing and dispatches *nothing* — e.g. a proxy's text/plain 502). `#failLoad` hides the frame (taking its stuck "Loading…" down with it), reveals the error block and moves focus into it; `retry` re-fetches by clearing `complete`/`src` and reassigning — no `loading` flip, since `#hasBeenLoaded` is set after the first attempt whatever its outcome and `sourceURLChanged` then fetches regardless of visibility. The retry URL comes from `turbo:before-fetch-request` (whose detail carries the genuinely-requested URL, immune to Turbo rewriting `src` to a redirected GET's final URL — a session expiry would otherwise pin every retry to the sign-in page), so **whichever controller points the frame needs no cooperation**; that same handler clears a stale failure the moment the next fetch starts. `loadSucceeded` un-hides the frame. **Loads only, never a form submitted inside the frame.** The two fetch events discriminate themselves — a `FormSubmission`'s `FetchRequest` carries the FORM as its target, so gating every handler on `event.target === frameTarget` excludes them (along with nested frames) — but `turbo:frame-missing` does **not**: Turbo dispatches it on `this.element`, the FRAME, unconditionally, including from `formSubmissionFailedWithResponse` → `loadResponse`. So frame-missing is claimed only while **armed**: `requestStarted` (which only fires for frame-targeted GETs) sets the flag and a load's end clears it. Unarmed, the event falls through untouched to Turbo's default — otherwise a 500 or auth bounce on an in-frame row save hid the whole editor/thread, along with the user's other typed edits, behind "Couldn't load…" whose Retry then re-GETs over that work. `connect()` likewise resets a failure state restored from a snapshot (fresh instance, no `requestedUrl`, and a hidden lazy frame can never re-fetch — permanently dead otherwise). Mounted on: the evidence modal panel, the request-evidence modal panel, each evidence card's discussion disclosure, and the explorer's binding-/level-editor modal bodies. |
| `evidence_modal_controller.js` | Drives the **unified evidence modal** (one modal for new/edit/respond, both surfaces). The page instance's `load` sets the lazy `#evidence-modal` frame `src` from a trigger's action params (mode + ids + entry cell + `return_to`), so the server renders the right form each open; the frame's *failure* state belongs to `frame-error` alongside it on the panel. The in-frame instance toggles the custom-type label and manages the "Applies to" link rows (each showing that cell's behavioural expectation + collapsible examples, read from an embedded JSON map) with the last-row remove lock. Replaced the old `evidence_form` / `evidence_edit_form` / `evidence_link_form` / `evidence_response` controllers. |

There is **no** `sticky_hero_controller.js`. The hero's collapse is pure CSS scroll-driven animation. See *Hero Summary — Collapse on scroll*.

## Lifecycle

Each enrolled `AssessmentCycleParticipation` walks a lifecycle the views render explicitly:

```text
enrolled → started → aligning → aligned ─┐
                        ↑___________|    ├→ concluded  (cycle closes)
   (manager re-opens, cycle still open)  │
              any pre-close state ───────┴→ withdrawn  (person unenrolled)
```

| Status | Trigger | What's editable |
|---|---|---|
| `enrolled` | `PersonEnrolled` lands | Self + manager ratings (incl. delegate) |
| `started` | First `SelfRated` / `ManagerRated` with `source: "human"` — unless made through a lens on a cell the home role doesn't read | Self + manager ratings (incl. delegate) |
| `aligning` | Manager fires `AlignmentStarted` against the home role | Aligned values on the home role's cells — self + manager FROZEN there |
| `aligned` | Manager fires `FullAlignmentCompleted` against the home role | The home role's cells: nothing |
| `concluded` | Cycle closed (`AssessmentCycleConcluded` on the PD stream) | Nothing |
| `withdrawn` | Person unenrolled (`LeftAssessmentCycle` on the PD stream) | Nothing |

This is the **home** lifecycle — `AssessmentCycleProgress#status`, which the list, the cohort report and calibration read. Alignment against any other role runs beside it (ADR-22):

| Per role | Trigger | Effect |
|---|---|---|
| started | `AlignmentStarted{role_id, cell_keys, level_ordinal}` | A `AssessmentCycleRoleAlignment` row (`aligning`); the role's cells disclosed to the assessee and frozen for self + manager ratings |
| completed | `FullAlignmentCompleted{role_id}` | Row `aligned`; the agreed values on its cells are that conversation's record |
| re-opened | `AlignmentReopened{role_id}` | Row back to `aligning`, agreed values kept |

- **Freeze is per cell.** A self or manager rating is frozen once *any* started role reads its cell — the union — so starting PM3 freezes the cells E3 shares with it on the E3 page (the pill's title says "Frozen — alignment against PM3 has started") while E3-only cells stay editable. The aggregate enforces it (`ensure_individual_ratings_unfrozen!(cell)` over `cell_keys`), the rating Operations refuse with the reason first, and the builder marks each cell `frozen_by`.
- **An agreed value moves** while an alignment reading the cell is in progress, and never where a completed alignment already agreed it (`agreed_locked` per cell; `Disclosure#agreed_value_locked?` mirrors the aggregate).
- **Completion gates are per role**, over that role's cells at the conversation's level: PM3's cells never block E3 and vice versa.
- **History has no role.** Every `AlignmentStarted` before per-role alignment carries neither `role_id` nor `cell_keys`: it is the home role's and freezes the whole assessment, exactly as it always did — the aggregate replays it as `cells: :all`, and the projection's row carries `whole_assessment: true`, which `Disclosure` reads to freeze every cell.

**Concluded vs withdrawn (deliberate distinction).** A cycle closing is a
*conclusion*, not a removal: the participant stays part of the cycle's
historical cohort (cohort reports, participant counts, and manager cohort
access all keep concluded rows — the enrollment `active` scope is
`not withdrawn`). An unrated enrollment still concludes — "concluded" says
only that the cycle ended around them, never how far they got (that stays on
the progress row). `withdrawn` exclusively means a person-scoped removal
(opted out, left the company, enrolled by mistake). Historical PD streams
retain `LeftAssessmentCycle(reason: "cycle_closed")` from before the two
concepts were separated (immutable; the aggregate now rejects that reason for
new commands). The enrollment read model heals independently: a `CurrentState`
rebuild replays the historical **`CycleClosed`** events (its own stream's
input — PD events are not) and re-derives those close-withdrawn enrollment
rows as concluded.

**Re-opening a completed alignment.** A completion made by accident is
recoverable: the assessee's direct manager (never a delegate or the assessee)
can re-open while the cycle is still open via the "Re-open alignment" button,
which fires `AlignmentReopened`. The cycle returns to `aligning` — the agreed
per-cell values are **preserved** (no clearing) and the original
`alignment_started_at` stamps are kept; only the completion stamps
(`aligned_at` / `aligned_by_id` / `aligned_framework_version`) are cleared. The
manager resumes editing agreed values and re-completes via the normal "Mark
alignment complete" path (auto-align is a *start*-time behaviour and is **not**
re-run). Gated by `AssessmentPolicy#reopen_alignment?` (manager + open cycle +
status `aligned`). `AlignmentReopened` is a new event with no production
history, so the `CurrentAssessment` projection added a handler without a
`CODE_VERSION` bump or rebuild. Surfaces as an `alignment_reopened` activity
entry (alignment group, visible to both parties).

**Threading the status to the views.** `MatrixDataBuilder` produces two page flags for the role being read — from `participant_status` on the home role, from the lens role's alignment otherwise — and two per cell:

- `individual_ratings_frozen` — the role's alignment has started. Threaded through `CapabilityCardExpansion` as `frozen:`. In self/manager context, the primary `FrequencyPill` renders as a static (non-interactive) coloured span instead of an interactive trigger.
- `alignment_locked` — the role's alignment is complete. Threaded as `alignment_locked:`. In alignment context, the alignment selector also becomes a read-only bar.
- `cell[:frozen_by]` — the started alignment that froze the cell, any role's; the pill renders static with "Frozen — alignment against PM3 has started".
- `cell[:agreed_locked]` — the agreed value can't move here (see *Lifecycle*).

Both flags also flow through the rating controllers' Turbo Stream responses so post-event re-renders pick the correct read-only / interactive shape.

**Header layout.** Both `ShowView` and `ManagerShowView` render a single-row header (`flex flex-wrap items-baseline gap-x-3 gap-y-1`):

- **Self view** — H1 is the level title; shortcode chip is `"#{role.code}#{level.ordinal}"`; status pill (`In Progress` / `Ready for alignment` / `Aligning` / `Aligned`) when a cycle is open.
- **Manager view** — H1 is `assessee.name`; subtitle span renders the level title; same shortcode + status pill.

**Status pill** (`Views::Assessments::StatusPill`, wrapped in `id="assessment-status-pill"` for Turbo replacement; the two header layouts share it via `HeaderChrome#render_status_pill`). The pill rewards finishing the current-level ratings *before* the manager-driven alignment phase: while a cycle is open and the participant is pre-alignment, it reads **"In Progress"** (amber) until **current-level coverage hits 100% with vetted (human-owned) ratings** in the viewer's perspective — carried-forward values don't count until confirmed — then a green finished label that says whose move it is: **"Ready for alignment"** in the assessee's view (their part is done; the manager starts alignment next, which a `Kit::DefinitionTip` on the pill spells out on hover and keyboard focus) and **"Assessment Complete"** in the manager's. The same "Ready for alignment" shows on the Home page's "Your assessment" card, read from the projected `self_completed_at`, whose CTA then reads "Review self-assessment". "Complete" is `MatrixDataBuilder#current_level_complete?` — every capability with a cell at `person_level` rated under the context's primary frequency (self ratings for `:self`, manager for `:manager`); a role with no current-level cells is never complete. Because the pill lives in the static header (outside the scoring/matrix Turbo Frames), the self and manager rating controllers `turbo_stream.replace` it on every rating change so it flips live the moment the final cell is rated — no reload. `aligning`/`aligned` still win and show "Aligning"/"Aligned". Before either, when every current-level cell holds a value but some were carried, it reads **"N to confirm"** in the dashed carried chip rather than a bare "In Progress" (#480).

**Assessments list — dual-party status.** The `/assessments` list ([index_view.rb](../../app/views/assessments/index_view.rb)) represents both parties. A **Team Assessments** (report) card shows a **Self** chip and a **Manager** chip, each `Not started` / `To confirm` / `In progress` / `Complete`; when both are complete it adds a quiet "Ready for alignment" cue. **Completion means VETTED THIS CYCLE**: carried-forward (seeded) values never count toward `Complete` — a side whose values are entirely carried reads **`To confirm`** (dashed amber chip, the carried signal shared with the pills and level chips), and any human touch (rate / revise / confirm / clear) tips it to `In progress`. The score/hero deliberately still count carried values (they're real data); the chips and pill track the *work state* — "here's the carried picture, your job this cycle is to vet it." A person's **own** card shows the **Self** chip only — the manager's progress stays private until alignment (privacy gate) — and the same "Ready for alignment" cue once their side is complete. The phrase means one thing everywhere: nothing on the viewer's side stands between this assessment and alignment. Once alignment starts, a single `Aligning` / `Aligned` chip replaces the per-side chips. "Complete" here is the **same current-level-coverage notion** as the header pill, so the Manager sub-badge and the report's "Assessment Complete" pill always agree.

**Skip-Level Assessments section.** Below Team Assessments, a manager-of-managers gets a **Skip-Level Assessments** section listing every assignment deeper in their org subtree. The Team/skip-level split has a single source of truth — [`Assessments::ReviewableAssignments`](../../app/queries/assessments/reviewable_assignments.rb) (`team` = direct reports + active rating delegations; `skip_level` = subtree minus team) — consumed by both the web controller and the MCP `assessments_mine` operation (`direct_reports:` / `skip_level_reports:` keys), so the two surfaces cannot drift. Cards reuse the report-card layout (both-party chips + "Review assessment") and open the manager view **read-only** — the whole manager chain has view access (see *Context-Driven Rendering*), while rating stays with each person's own reporting manager. The section is **paginated with pagy** (`AssessmentsController::SKIP_LEVEL_PAGE_SIZE` per page, `?skip_page=` param, prev/next pager anchored to `#skip-level-assessments`) because a senior manager's subtree can hold hundreds of assignments.

The per-side `Complete` is a **projected, event-sourced fact**: [`CurrentAssessment`](../../app/contexts/person_development/projections/current_assessment.rb) runs [`Assessments::LevelCoverage`](../../app/queries/assessments/level_coverage.rb) on every rating change and stamps `assessment_cycle_progress.self_completed_at` / `manager_completed_at` (original completion time preserved across edits that stay complete; cleared when coverage drops). `status` stays the lifecycle phase — the two sides complete independently, so completion can't live in a single enum. The index reads those timestamps plus one cheap "any rating per side" query for the `Not started` vs `In progress` distinction (which needs no framework structure). `LevelCoverage`'s denominator mirrors `MatrixDataBuilder` exactly (active, role-bound capabilities with an expectation at the assessed level), pinned by a test. Known limitation: a `FrameworkVersionMigrated` that changes the current-level cell set without a subsequent rating can leave a stale flag until the next rating.

**Action cluster (right side).** Manager view with status `started` shows "Start alignment" (form with `data-turbo-confirm`); status `aligning` shows the gated "Mark alignment complete" control (below); status `aligned` shows "Re-open alignment". Status `aligning` or `aligned` automatically renders in alignment mode — no toggle. On a lens role the same two milestone controls act on that role's alignment (see *Per-role alignment*); its start lives in the lens banner.

**Completion gate (full current-level aligned coverage).** Marking alignment complete requires **every current-level capability to carry an agreed value**, so `aligned` status always means the formal record is whole — no cell scoring a silent 0.0 in the aligned perspective, and cross-cycle seeding never starts from gaps. Alignment is a shared act — either party can record agreed values — and the manager (who alone completes) can always record them, so the gate can never deadlock: it forbids leaving cells *implicit*, not disagreement (auto-align at start already clears explicit agreements; the residue is exactly the set that deserves the conversation). Enforced in **two layers**, both inside `Operations::Assessments::CompleteAlignment` (web and MCP): the aligned side of [`Assessments::LevelCoverage`](../../app/queries/assessments/level_coverage.rb) over the role being completed gives the friendly count, then the counted cells go into `complete_alignment` as `required_cell_keys`, which the **aggregate re-checks atomically** against its replayed `@aligned_ratings` — serialized with any concurrent align/clear on the same stream, so a race can't slip a gap into the completed record. The split is deliberate: the denominator (which capabilities have a cell at the level) is framework structure the PersonDevelopment stream doesn't carry, so the edge supplies it and the aggregate enforces it. A cell a role gained after its alignment started (a framework publish mid-conversation) joins the role's cells when it is agreed against that role (`align_assessment(role_id:)`), so the gate never counts a cell nobody could agree. A role with zero current-level cells never blocks (mirrors the hero's zero-cell unlock). The UI mirror is `Views::Assessments::AlignmentCompletionControl` (`id="alignment-completion-control"`, desktop-only like the other milestone buttons): a disabled button + an amber "N to align →" jump chip (reusing the `continue-assessing` window-event bridge via the shared `ContinueAssessingLink`) while cells remain; the alignment-rating Turbo Stream responses replace it in place so it enables the moment the last cell is agreed. That live update is **actor-side only** — like the status pill and every other static-header element — so when the *assessee* records the final agreement, the manager's control catches up on their next interaction/reload (the acting-user convention; see framework-explorer.md Hard-Won Lesson 21).

**`AlignmentStartsController` / `AlignmentCompletionsController` / `AlignmentReopeningsController`** dispatch `Operations::Assessments::{StartAlignment,CompleteAlignment,ReopenAlignment}` (shared `Assessments::AlignmentMilestone` concern), each taking the lens's `as_role` / `as_level`, and redirect back to the page read through that lens. The Operations ask the per-role `AssessmentPolicy` predicates themselves — Pundit's `authorize` passes no role.

**Auto-alignment on start.** Inside the same RES transaction as `AlignmentStarted`, `PersonDevelopment::CommandHandler#start_alignment` emits an `AssessmentAligned` event for every (capability × level) cell **of the role being started, not already agreed,** where both `self_rated_frequency` and `manager_rated_frequency` are explicitly recorded **and equal**. The conversation in alignment mode then focuses on disagreements and unrated cells. Default-fallback agreements are NOT auto-aligned. Auto-aligned events carry the comment "Auto-aligned: self and manager already agreed".

**Cross-cycle seeding (carry-forward, ADR-20).** When a person enrols in a
new cycle, their ratings are pre-populated from their **most recent prior
participation** in the framework — aligned or not — with **per-cell
precedence**: a cell the parties agreed on carries the aligned value into
both sides (shared truth); a never-agreed cell carries each perspective's
own last value forward, so the alignment conversation resumes where it
stopped instead of starting blank. A side that never rated stays empty —
seeding records what existed, never fabricates agreement.
Most-recent-participation is lossless by construction: seeding chains, so
an unaligned cycle already contains the previous aligned baseline plus
whatever moved since. Seeded events carry `source: "seeded"` (vs the
default `"human"`) and `seeded_from_cycle_id`; idempotency is **per side**
(a human-touched side is never overwritten; the other side can still
seed). The participant stays in `enrolled` until their first real edit —
seeded events alone do not trigger `started`.

> This deliberately reverses the original aligned-cycle-only gate ("a
> partially-aligned cycle isn't a valid carry-forward baseline"): the
> alternative to an imperfect baseline is not a better baseline, it is
> blank — which punished a report for their manager's incomplete
> alignment (observed as inconsistent seeding across the Q3 2026 cohort).

**Carried-rating affordance.** A seeded rating the viewer hasn't confirmed
renders **distinctly from a fresh rating**, mirroring the below-level
assumed-consistent precedent (lighter = inherited, solid = explicit): the
`FrequencyPill` shows a dashed outline in the frequency's hue
(`pill_carried` in the palette), reads "Most of the time · confirm", and its
menu leads with **"Keep “Most of the time”"** under a note naming where the
value came from; a level chip whose
solid fill is entirely carried uses the lighter `chip_carried` tint (split
slices deliberately keep full tint — carried state there is visible on the
expansion pills). Non-visual parity via `title`/aria. Provenance is
**per side** on the read model (`self_rating_source` /
`manager_rating_source` — the row-level `source` flips to human on any
touch and can't say which side is still carried). **Interaction:**
selecting the shown value on a carried pill **confirms** it (re-emits as
human; the pill solidifies); untoggle-to-clear applies only to ratings the
person made themselves, and the popover's "Clear rating" posts an explicit
`rating[clear]` marker since the same-frequency POST is no longer
unambiguous.

**The confirmation work is named, not implied (#480).** A dashed outline was
the only signal, and people believed they had finished
([#480](https://github.com/mr-yum/growth-os/issues/480)). So:

- **Only cells that ask are marked.** `MatrixDataBuilder` reports a side as
  carried only at or above the scoring floor (`assumed_below`, the lower of
  the lens and home levels). Below it an unrated cell already reads as met
  and nothing counts it, so a carried value there wears no dashed treatment.
  Seeding still carries it: a lens at a lower level, or a later move to one,
  reads the value ([#481](https://github.com/mr-yum/growth-os/issues/481)
  explains why it isn't dropped).
- **Each surface says it.** The status pill reads **"N to confirm"** once
  every current-level cell holds a value (`current_level_work`); the hero
  swaps Continue for a "N to confirm →" jump chip at that point; a carried
  capability's name row wears **To confirm**. All three use
  `Components::Kit::ToConfirmChip`, and "still asks" is one predicate,
  `Concerns::RatedCount.to_confirm?` (carried on the viewer's side, not
  frozen).
- **A category confirms in bulk.** Its indicator cluster offers
  "Confirm N carried", a page (`Assessments::CarriedRatingsController`)
  listing every carried cell ticked, with its expectation and the feedback
  recorded this cycle beside it, so the confirm is informed. It posts to
  `Operations::Assessments::ConfirmCarriedRatings`, the same code as the
  `assessments_confirm_carried_ratings` tool. **That operation checks each
  cell is still carried before confirming it**: re-sending a value that is
  already human-owned through `RateSelf` *clears* it (the untoggle), so a
  stale list skips the cell rather than wiping it. Home role only; a lens
  confirms through its own pills.

**Bulk enrollment is a background job** (`AssessmentCycles::BulkEnrollmentJob`)
— each enrollment replays the person's PD stream and seeds carried ratings,
so a real cohort inline reliably times the request out. Per-person
transactions; skip-on-domain-failure; safe to re-run.

## Hard-Won Lessons

### 1. Separate view hierarchies over multi-mode components

A parallel `app/views/assessments/` hierarchy with its own card/strip/chip components was cleaner than adding mode parameters to the framework explorer's view. Assessment components need frequency selectors, secondary bars, contribution badges, and color-tiered chip backgrounds that don't belong in the read-only explorer.

### 2. Context threading must be end-to-end

The `:self` / `:manager` / `:alignment` context flows from controller detection through the builder, into every view component, and into form action URLs. Missing the context at any layer — especially `FrequencyPill#form_action` — routes ratings to the wrong endpoint silently.

### 3. Perspective scoring returns nil, not empty

`build_perspective_scoring` returns `nil` (not an empty hash) when no ratings exist for a perspective. `HeroSummary` falls back to effective scoring when its preferred perspective is nil. Returning an empty hash would display misleading zero scores.

### 4. The middle band must point at the *next* milestone, not one already cleared

An early state machine fired a separate `:progressing_to_next` state whenever the next-level ratio cleared the underperforming floor — pointing at promotion before the person had consolidated their own level. The mental model is *always-the-next-gate*: `:performing` owns the band from meeting to the mastery waypoint and is framed as progress toward the next level, using next-level contributions so the gap values actually mean something (capabilities at `+0.0` current would show `-1.0` at L+1 — the real signal). With the level-independent scale (ADR-21) the number itself says how far along that band the person is, so the headline carries it ("38% of the way to E4") instead of a separate state.

### 5. CSS scroll-driven animation needs `grid-template-rows`, not `max-height`

The original hero collapse animated `max-height` + `padding-block`. That caused a re-layout feedback loop mid-scroll — visible as a flicker between hidden and visible — because the unified sticky header height was changing every frame, which `category_nav_controller`'s ResizeObserver published as `--sticky-header-h`, which cascaded layout, which …

`grid-template-rows: 1fr → 0fr` owns the row's height locally. Two-layer wrapper (grid item with no padding, padded child inside) lets the row shrink to 0 without padding contributing to a minimum height.

### 6. Sub-pixel rounding leaves a 1px gap under the sticky header

`element.offsetHeight` returns an integer. When the real sticky-header height is fractional (Hi-DPI displays, mid-animation), `--sticky-header-h` lands 0.5–1px short of the actual bottom edge, and the category section's `top: var(--sticky-header-h)` ends up a hair below the unified header — revealing a thin strip of scrolling content. Use `Math.ceil(getBoundingClientRect().height)` instead.

### 7. Active-chip detection must be locked during programmatic scroll

The smooth-scroll animation's final scroll event can fire while the target section's top is still a few pixels short of the active-detection threshold. Without a lock, the active marker reverts to the previous chip — the clicked chip appears to mismatch the visible section. `category_nav_controller` locks the active state for ~900ms after a chip click and suppresses scroll-based detection during that window.

### 8. Capability contribution must render as a signed delta, never hidden when negative

The original card had `return if @contribution.negative?` and rendered the contribution as a percentage. That silently dropped the most informative signal (under-performance) and showed even `+0.0` as `0%` — meaningless. Render as `±N.N` always; color-tier by magnitude.

### 9. Auto-focus removes the "no level focused" state — drop the close button with it

The original card had a `×` close button on the expansion panel that returned to "no level focused" — strip visible, panel hidden. Auto-focusing every card on the person's level makes that state meaningless (there's nothing to close *to*). Re-focusing means clicking a different chip; that's the only interaction the strip needs.

### 10. Rating Turbo Streams must re-render with the right mode + context

Inline rating responses use `turbo_stream.replace` on the rated cell or expansion. The replacement must carry both `context:` and `frozen:` / `alignment_locked:` from the parent view, otherwise the re-rendered fragment loses the read-only treatment in `aligning` / `aligned` states.

### 11. IntersectionObserver's connect-time callback isn't a user scroll

`new IntersectionObserver(cb).observe(el)` triggers `cb` once with the current intersection state — not in response to a user scroll, but as a one-shot bootstrap. Acting on that callback to update capability focus made every page load auto-narrow the activity feed to whichever card happened to sit in the visible band, silently overriding URL-driven (`?capability=`) and click-driven initial focus. Fix: gate `#updateFocusedCapabilityFromScroll` on `_sawUserScroll`, which only flips after a real `scroll` event has fired. Real users always trip the flag with their first scroll; the bootstrap callback no-ops.

### 11a. "Deepest card past the sticky chrome" is symmetric in mechanism but asymmetric in perception

First version of `#updateFocusedCapabilityFromScroll` picked the deepest card whose top had scrolled past `stickyH + 16` — same heuristic `category_nav_controller#updateActiveCategory` uses for category sections. Worked great scrolling down (the new card appears at the chrome line, focus switches naturally). Broke scrolling up: when the current card's top crossed back below the threshold, the "next" card in the set was the one ABOVE the chrome, often far above with only its bottom edge visible. Focus jumped to a card the user couldn't yet see.

The cause: with downward scrolling the threshold-crossing card is also the one growing visibly in the band; with upward scrolling the same crossing dismisses the visible card while crowning one that's mostly off-screen. Fix: switch to a most-visible-area picker. The card with the most pixels in the content band (viewport strip below sticky chrome) wins regardless of scroll direction. Both directions converge on "what the user has the most of on screen", which is what they're reading.

### 12. Activity feed reconnect on lazy-frame load needs a DOM signal for capability focus

`activity_feed_controller#readMatrixFocusFromDom` runs on every `connect()`. The activity sidebar lives in a `loading: "lazy"` turbo-frame, so its first connect (when the pane opens) happens AFTER the user may have already clicked a card. Without a DOM signal for "capability focus is active on card X", the reconnect would default to category-level focus and silently undo the click. The signal is `data-focused="true"` on the matching card — server stamps it from `?capability=`, JS toggles it on focus changes, feed reads it on reconnect.

### 13. Renew-on-scroll suppression beats a fixed time window

The first version of the explicit-click suppression was time-only: `_capabilityFocusSuppressUntil = Date.now() + 900`. On slow CI runners the smooth scroll that an explicit click triggers routinely outlasted 900ms — even after bumping to 1800ms the picker could fire mid-animation and overwrite the user's focus with whichever card was the area-winner at that frame. Fix: pair the time-based window with a `_suppressionScrollRenew` flag plus a `_scrollSettleTimer` that every scroll event resets. The flag stays true until scroll events have been quiet for 2000ms, so the suppression naturally tracks the actual animation duration regardless of CI speed. Time-based covers the click itself; renew-on-scroll covers the scroll animation. Both are needed — neither alone survives the full range of CI timing.

### 14. IntersectionObserver callbacks aren't load-bearing for the picker

The original picker iterated `_intersectingCards`, a `Set` maintained by the `IntersectionObserver` callback. On slow CI the IO callback fires arbitrarily late — the picker would run with a stale or empty set when the test asserted. Fix: iterate `cardTargets` directly inside the picker and compute visible area via `getBoundingClientRect()` for each card. The IO is still useful as the scroll-event flusher (it triggers `#scheduleCapabilityScrollUpdate` from the callback) but it's no longer the source of truth for *which* cards the picker considers. Genuine user scrolls drive the picker via `_onCapabilityScroll`; the IO callback only renews suppression for layout-shift-driven re-fires.

### 15. External category focus must be sticky against the scroll picker

The picker's "don't override" check originally only honoured `cell` / `capability` focus on the same card — `category` always fell through and got rewritten to `capability` focus on whatever card was the area winner. That meant a deliberate chip click would persist for the suppression window, then silently downgrade the moment a single scroll event landed past the renew timer. Fix: track external category dispatches with a `_categoryFocusFromExternal` sticky flag (set in `#onExternalFocusChange` when `detail.level === "category"`, cleared in `#setFocus` whenever the new level is anything else). The picker checks the flag the same way it checks for same-card cell/capability focus. Initial default category focus from `#dispatchInitialFocus` doesn't set the flag, so the first user scroll on a fresh page still narrows to capability focus as expected — only chip-set category focus is sticky.

### 16. A scroll-driven animation that resizes an in-flow element shakes — two couplings, two fixes

The hero middle band collapses via `animation-timeline: scroll(root)`, and the band sits inside the **unified sticky header, which is in normal document flow** at the top of the page. So as the band collapses, the header's flow box shrinks *above the fold* — and that couples scroll position back into the scroll-linked animation in **two independent ways**, each producing a visible "shake" of the band when the resting scroll lands inside the 0–240px collapse range ("close to full visibility but not quite"):

1. **Scroll anchoring** (fires on *any* page during active scroll). The browser, by default, nudges `scrollTop` to keep below-fold content visually stable when content above it resizes. The header shrinking triggers that nudge → re-drives the animation → resizes the header → … Fix: `overflow-anchor: none` on the page's scroll-root subtree, so the band collapses purely as a function of genuine user scroll.

2. **Scroll-range clamping** (the "sometimes" / short-page case). On a marginally-scrollable page the collapse shrinks the document below `scrollTop`, so the browser **hard-clamps** the scroll down, which re-expands the band, which restores the scroll length — a sustained ~1px limit cycle. Clamping is a hard constraint `overflow-anchor` can't suppress. Fix: a `min-height` floor (collapse range + band-height headroom, on top of the viewport) on the same scroll-root — on a short page the collapse is absorbed by the floor instead of shrinking the document, so the scroll length stays constant and never clamps; on a normal (tall) matrix it's a no-op.

Both live on `.assessment-scroll-root` (the `assessment-sync` wrapper in `show_view.rb` / `manager_show_view.rb`), gated inside `@supports (animation-timeline: scroll())` so they only apply where the collapse — and thus the loop — actually runs. The trap is assuming `overflow-anchor: none` alone fixes it: it kills the anchor loop but not the clamp loop, which is the one the bug report ("shakes near full visibility, sometimes") actually describes. Verified in-browser: before, a held scroll position oscillates the band through several heights; after, every position holds a single stable height. Regression-guarded by `assessments_system_test.rb` → "apply the anti-shake CSS to the assessment scroll root".

### 17. Toggling Tailwind `hidden` on an element that already has a `display` utility doesn't hide it

The request modal hides a suggestion chip once it's been added to the recipient list. The first cut toggled the `hidden` class — and the chip stayed visible. Cause: the chip carries `inline-flex` (a `display` utility), and `.hidden { display:none }` ties it on specificity (both single-class selectors), so **source order decides** — Tailwind emits `inline-flex` after `hidden`, so `inline-flex` wins and `.hidden` is a no-op. The class *is* present in the DOM (so a `classList.contains("hidden")` check misleads you into thinking it worked); it just has no visual effect. Fix: toggle an **inline** `el.style.display = "none" / ""` (inline style beats any class), or render the element without a competing display utility. See `request_evidence_controller.js#toggleSuggestion`. The general rule: never rely on `hidden` to override another `display-*` utility on the *same* element — gate visibility from a parent, or use inline style.

### 18. Per-card selected level needs its own *rendering* axis, separate from the single *focus* axis

The selected level a card's expansion shows was originally carried by the **same** `?capability=` + `?level_ordinal=` pair that drives cell focus (ring + activity narrowing). Because that pair holds exactly ONE capability, only one card could ever show a non-default level: selecting a level on a second capability reloaded the whole matrix frame and re-rendered every other card at `@person_level` (the URL named only the new one), and the scroll-driven picker — which rewrites that pair as you scroll — *dropped* `level_ordinal` entirely, so the selection silently vanished on the next broadcast reload. The two concerns look identical (both are "a capability + a level") but have different cardinalities: **focus is singular and transient; rendered level is plural and sticky.** Conflating them caps persistence at one card and couples it to scroll. The fix is a second, additive URL axis — `levels[<stable_id>]=<ordinal>`, an accumulating map the server renders each card from (`selected_levels[stable_id] || person_level`) and that the scroll picker never touches. Lesson: when one piece of UI state is per-entity-and-sticky and another is one-at-a-time-and-transient, give them separate URL params even if each value is "a capability and a level" — don't overload one slot for both.

### 19. A sticky pane under a moving header can't be sized by CSS alone

The activity sidebar is sticky at `top: --sticky-header-h + 1rem` and was capped at `100vh - 2rem`, which ignored the header and left the pane's bottom, and the feed's last entries, several hundred pixels below the viewport ([#470](https://github.com/mr-yum/growth-os/issues/470)). Subtracting the header (`100dvh - --sticky-header-h - 2rem`) is right only once the pane has stuck. Before that, at the top of the page, the navbar above the header pushes the pane lower than its sticky offset, and the bottom is still off screen. `overscroll-contain` makes that worse, since the wheel can no longer move the page to reveal it. So `activity_pane_controller` measures the pane's own top and sets `max-height` to what is left below it. The CSS cap stays as the pre-JS fallback, and both offsets are `lg:`-only: an inline `top` also overrode the phone overlay's `inset-y-0`, so it opened a rem below the top of the screen.

## Performance state machine

Defined in `PersonDevelopment::Scoring#performance_state`. See [scoring-model.md](../architecture/scoring-model.md) for the canonical definition. Summary:

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

## Future Extension Points

- **Framework version migration UI for skipped seed values** — `RatingSeedSkipped` events are emitted but no read model / UI surface consumes them yet.
- **Growth Plans** — events defined (`GrowthGoalSet`, `FocusAreaAdded`, `CheckInRecorded`), no UI yet.
- **Notifications and Snapshots** — both are listed in architecture docs; neither has any infrastructure today.

## File Reference

| File | Purpose |
|------|---------|
| **Page-level views** | |
| `app/views/assessments/show_view.rb` | Self-assessment shell — unified sticky header + main column + activity sidebar |
| `app/views/assessments/manager_show_view.rb` | Manager assessment shell — same shape, different H1 + action cluster |
| `app/views/assessments/index_view.rb` | Assessment list (own + direct reports) |
| `app/views/assessments/status_pill.rb` | Header status pill — In Progress / N to confirm / Assessment Complete / Aligning / Aligned; Turbo-replaceable (`id="assessment-status-pill"`) |
| `app/components/kit/to_confirm_chip.rb` | The dashed amber "to confirm" chip — status pill, card name row, list cards, the hero and category links |
| `app/controllers/assessments/carried_ratings_controller.rb` | A category's carried ratings: the review page (GET) and the bulk confirm (POST → `ConfirmCarriedRatings`) |
| `app/views/assessments/carried_ratings/index_view.rb` | The review page — every carried cell ticked, with its expectation and this cycle's feedback |
| `app/operations/operations/assessments/confirm_carried_ratings.rb` | Shared web + MCP bulk confirm — checks each cell is still carried, then confirms through `RateSelf` / `RateAsManager` |
| `app/views/assessments/header_chrome.rb` | Shared header chrome for both show views — the lens control, the status pill or lens banner, the lens modal, and `lens_params` for frame srcs |
| `app/views/assessments/lens_control.rb` | The shortcode chip as the lens control — the role's ladder, "Back to E3", "Another role…" (see *Role lens*) |
| `app/views/assessments/lens_role_modal.rb` | "Read against another role" — GET form, role by family, level kept at the reader's ordinal |
| `app/views/assessments/lens_banner.rb` | The lines that replace the status pill under a lens — what it reads against, and where alignment against the lens role stands (with the manager's start) |
| `app/views/assessments/start_lens_alignment_modal.rb` | "Start alignment against PM3?" — the confirmation, a `Kit::Modal` form |
| `app/views/assessments/lens_alignment_chips.rb` | "Aligning · PM3" chips linking into each started lens role |
| `app/queries/assessments/lens_alignments.rb` | The started lens-role alignments per participation — list cards and the home page |
| `app/models/assessments/disclosure.rb` | Disclosed and frozen cells — the union of started roles' scopes (see *Lifecycle*) |
| `app/read_models/assessment_cycle_role_alignment.rb` | One row per role alignment has started against (home included), written by `CurrentAssessment` |
| `app/operations/operations/assessments/{start,complete,reopen}_alignment.rb` | The alignment milestones, web and MCP, per role (`AlignmentLens` resolves the role) |
| `app/contexts/person_development/async_handlers/lens_alignment_notifier.rb` | Tells the assessee when alignment against another role starts |
| `app/javascript/controllers/lens_picker_controller.js` | Rebuilds the lens modal's level select on a role change |
| `app/read_models/assessment_exploration.rb` | A declared exploration (ADR-22) — PK the event-carried id, written by `CurrentAssessment` |
| `app/queries/assessments/open_explorations.rb` | Open explorations per assessment, with target-level progress for the person's own list |
| `app/views/assessments/{start,stop}_exploration_modal.rb` | "Keep exploring this" / "Share with Alex" and "Stop exploring" dialogs (shared form in `exploration_modal_form.rb`) |
| `app/views/assessments/exploration_chips.rb` | "Exploring PM3" chips on a report's card, linking into the lens |
| `app/controllers/assessments/{explorations,exploration_closures}_controller.rb` | Declare / close from the lens banner → the shared Operations; back to the lens |
| `app/operations/operations/assessments/{start,close}_exploration.rb`, `explorations_list.rb` | Declared explorations, web and MCP (`ExplorationPayload` is the one shape) |
| `app/contexts/person_development/async_handlers/exploration_notifier.rb` | Tells the other party when an exploration starts or closes |
| **Hero summary** | |
| `app/views/assessments/hero_summary.rb` | Three-band hero card with state-driven middle band; renders inside the unified sticky header |
| `app/views/assessments/glossary.rb` | The assessment vocabulary — built per request so every definition names the viewer's level codes, the framework's configured bands and the tenant's words; `SCALE_SENTENCE` is shared with the calibration glossary |
| `app/views/assessments/concerns/defined_terms.rb` | `defined_term(key)` — renders a scored term with its definition attached, through `Kit::DefinitionTip` (hover AND keyboard); `weight_chip` / `required_chip` — the ONE drawing of the binding chips the card, the hero gap list and the explainer share |
| `app/views/assessments/score_explainer_modal.rb` | "How is this calculated?" — the viewer's own arithmetic first, then the rules, then what doesn't count |
| `app/views/assessments/state_labels.rb` | The ONE reader of a state's word — the tenant's own if it set one, else the word GrowthOS ships (#415) |
| `app/operations/operations/tenants/update_scoring_vocabulary.rb` | Shared web + MCP operation — rename the performance states for a tenant (labels only; the states and thresholds are untouched) |
| `app/views/assessments/concerns/score_scale.rb` | The ONE score vocabulary every altitude reads — tone by state, state words, level codes relative to the assessed level, the band count the bar draws |
| `app/views/assessments/score_bar.rb` | The scale made visible at three sizes (`:lg` hero / `:md` category / `:sm` card) — one segment per band, tick-labelled with level codes at hero size only |
| **Category navigation** | |
| `app/views/assessments/category_chip_bar.rb` | Sticky chip row, active marker, per-category state dot + percent (both behind the coverage gate) |
| `app/views/assessments/category_indicators.rb` | A category's score at its section head — rated count, split, tone-coloured percent (state as a `title`, never a word), `:md` bar, divergent-perspective annotations |
| `app/views/assessments/category_section.rb` | Anchor target + sticky section heading + stack of capability cards |
| **Matrix content** | |
| `app/views/assessments/assessment_matrix_frame_view.rb` | Turbo Frame wrapper for the matrix |
| `app/views/assessments/assessment_matrix.rb` | Container that renders each `CategorySection` |
| `app/views/assessments/capability_card.rb` | One card per capability — eyebrow, name row, level strip, expansion panel |
| `app/views/assessments/capability_name_row.rb` | The card's name row — name, the `×N` / Required chips ([#431](https://github.com/mr-yum/growth-os/issues/431)), Blocked badge, and the capability's own score with its split (`id="capability-name-<stable_id>"`, Turbo-replaced by the rating controllers) |
| `app/views/assessments/level_strip.rb` | Horizontal flex of `LevelChip`s, scrolls horizontally on narrow |
| `app/views/assessments/level_chip.rb` | One chip per level — solid fill by frequency, diagonal split on disagreement / partial rating (colour vs grey), evidence/comment glyphs, YOU/CURRENT current-level badge |
| `app/views/assessments/capability_card_expansion.rb` | Focused-level panel — expectation sentence + inline FrequencyPill, divergent SecondaryRatingLines, illustrations, evidence, comments |
| `app/views/assessments/frequency_palette.rb` | Shared 4-state colour palette + sentence phrases for pill / chip / dot |
| `app/views/assessments/frequency_pill.rb` | Inline rating pill (interactive popover or static coloured span) |
| `app/views/assessments/secondary_rating_line.rb` | Divergent-perspective sentence with a colour-coded dot |
| `app/views/assessments/rating_error.rb` | Rating error flash partial |
| **Activity feed** | |
| `app/views/assessments/activity/feed.rb` | Right sidebar — entry list, filter chips, focus mode toggle |
| `app/views/assessments/activity/filter_chips.rb` | All / Ratings / Evidence / Comments / Alignment (wraps onto multiple lines) |
| `app/views/assessments/activity/focus_mode_toggle.rb` | Highlight / Filter segmented control |
| `app/views/assessments/activity/entry.rb` | Single entry — author, title, body, badges |
| `app/views/assessments/activity/feed_frame_view.rb` | Turbo Frame wrapper for the activity feed |
| `app/views/assessments/activity/pane_toggle.rb` | Activity button in the header — opens/closes the sidebar |
| **Delegation** | |
| `app/components/kit/modal.rb` | Reusable modal (standalone w/ trigger, or embedded); hosts the Delegates + evidence modals |
| `app/views/assessments/delegations/frame.rb` | `delegations-list` Turbo Frame — add-form + active-delegate list (revoke) |
| **Controllers** | |
| `app/controllers/assessments_controller.rb` | show / index / matrix / scoring / activity — self/manager/alignment context routing; index unions delegated reports; show loads delegates |
| `app/controllers/assessments/delegations_controller.rb` | Grant / revoke a manager-rating delegation (Turbo Frame; dispatches `Operations::Assessments::{Delegate,Revoke}…`) |
| `app/controllers/assessments/ratings_controller.rb` | Self-rating POST (rate_self, revise, clear) |
| `app/controllers/assessments/manager_ratings_controller.rb` | Manager-rating POST (rate_as_manager, revise, clear) |
| `app/controllers/assessments/alignment_ratings_controller.rb` | Per-cell alignment POST (align_assessment) |
| `app/controllers/assessments/alignment_starts_controller.rb` | Manager-only POST — fires `AlignmentStarted`, locks individual ratings |
| `app/controllers/assessments/alignment_completions_controller.rb` | Manager-only POST — fires `FullAlignmentCompleted`, freezes all ratings |
| `app/controllers/assessments/alignment_reopenings_controller.rb` | Manager-only POST — dispatches `Operations::Assessments::ReopenAlignment`, returns the cycle to `aligning` (agreed values preserved) |
| `app/operations/operations/assessments/reopen_alignment.rb` | Shared web + MCP operation — re-open a completed alignment (manager-only, cycle still open) |
| **Notifications** | |
| `app/contexts/person_development/async_handlers/comment_notifier.rb` | Async handler: `CommentPosted` → reply / assessee / manager-side notifications (see *Comment notifications*) |
| `app/notifiers/{comment_reply,assessment_commented,team_assessment_commented}_notifier.rb` | Presentation per notification type — title, excerpted body + context line, cell deep link |
| **Data** | |
| `app/queries/assessments/role_scope.rb` | The ONE definition of the cells a role reads (ADR-22) — active bound capabilities × their expectations, plus the bindings scoring uses; every rating reader filters through it via `AssessmentLevelRating.within` |
| `lib/rubocop/cop/growth_os/ratings_must_be_role_scoped.rb` | Fails CI on a rating query that never passes through `.within` or `.across_all_roles` |
| `app/models/assessments/matrix_data_builder.rb` | Single-role builder — ratings + 4 scoring perspectives + `performance_state` + next-level contributions + `current_level_complete`. Resolves the **assessed level** from the cycle's enrollment snapshot (same-role gate), not the live assignment level — see [ADR-19](../architecture/adrs.md) |
| `app/models/assessments/secondary_perspectives.rb` | The ONE list of the perspectives shown beside the viewer's own — each carrying its context, so a secondary annotation can be held to the coverage gate against its own ratings |
| `app/models/assessments/viewer_context.rb` | The ONE `:self` / `:manager` / `:alignment` resolution — the web controller and the MCP read tools both call it, so a score can't be built from ratings the viewer may not see; a lens on another role never reads as `:alignment` |
| `app/models/assessments/lens.rb` | The role and level a page is read against, with its home (ADR-22) — resolved once per request, threaded wherever a role goes |
| `app/models/assessments/disclosure.rb` | The cells whose manager / aligned values the assessee may see — the home scope once home alignment starts |
| `app/operations/operations/assessments/rating_cell.rb` | The rating Operations' shared cell check (`as_role_id`), `via_role_id` stamp and the manager-side home-scope refusal |
| `app/operations/operations/assessments/read_lens.rb` | The MCP read tools' lens resolution and `in_role` overlay |
| `app/queries/assessments/score_summary.rb` | The MCP read tools' score payload — runs the same `MatrixDataBuilder` the web renders and reshapes its scoring into whole percents plus the scale's own meaning |
| `app/queries/assessments/level_coverage.rb` | Current-level self/manager/aligned completion for a (person, framework, cycle). Its denominator is the role scope at the assessed level, the builder's cells; consumed by the `CurrentAssessment` projection to stamp `assessment_cycle_progress.{self,manager}_completed_at` for the dual-party list status, and by the alignment-completion gate (aligned side) |
| `app/views/assessments/alignment_completion_control.rb` | Gated "Mark alignment complete" header control — disabled + "N to align →" jump chip until current-level aligned coverage is whole; Turbo-Stream-replaced on every alignment rating |
| `app/views/assessments/continue_assessing_link.rb` | Shared "jump to a capability cell" anchor — sole owner of the `continue-assessing` href/data contract (hero CTA, priming CTA, completion jump chip) |
| `app/read_models/assessment_level_rating.rb` | Three-frequency read model (self / manager / aligned) |
| `app/read_models/person_framework_assignment.rb` | Person-framework-role-level assignment |
| `app/read_models/recorded_reporting_manager.rb` | Recorded reporting manager — authoritative for manager-rating authority |
| `app/read_models/manager_assessment_delegation.rb` | Active/revoked rating delegations; `active` scope + `candidate_people` |
| **JavaScript** | |
| `app/javascript/controllers/matrix_controller.js` | Chip-click focus, smooth-scroll, URL sync, sibling dimming (shared with framework explorer) |
| `app/javascript/controllers/category_nav_controller.js` | `--sticky-header-h` publish, chip-click scroll, active-chip detection on scroll |
| `app/javascript/controllers/assessment_sync_controller.js` | ActionCable sync, self-submit suppression, dual-frame reload, focus-param merge |
| `app/javascript/controllers/activity_feed_controller.js` | Focus-narrowing on `matrix:focus-changed` |
| `app/javascript/controllers/continue_assessing_controller.js` | Bottom-line CTA — dispatches focus-unrated event |
| `app/javascript/controllers/modal_controller.js` | Generic `Kit::Modal` open/close/Esc; opt-in outside-click dismissal (`dismissOnOutsideClick`, default off); dispatches `modal:open` |
| `app/components/kit/modal.rb` | The panel is capped at `max-h-[90dvh]` with a pinned header and a scrolling body — a modal taller than the viewport used to centre and push its own title and × off the top edge, leaving Esc as the only exit and nothing on screen saying so |
| `app/javascript/controllers/evidence_modal_controller.js` | Drives the unified evidence modal — frame `load`, link rows, type toggle (shared with the hub) |
| `app/javascript/controllers/frame_error_controller.js` | Shared lazy-frame failure state — error + Retry in place of a stuck "Loading…" (see the controllers table) |
| `app/components/kit/frame_load_error.rb` | The hidden `role="alert"` block `frame-error` reveals — Retry, plus an optional Close for modals (whose own ×/Cancel went down with the hidden frame). Callers pass `subject:` ("the form", "the discussion") and the sentence — including whether its tail says "close this" — is built from `subject:` + `closeable:`, so the copy can't promise an exit the site doesn't render. Owns `BUTTON_CLASSES`, the canonical secondary-button treatment the evidence forms' `SECONDARY_BTN` point at |
| **Unified evidence modal** (one modal for new/edit/respond, assessment + hub) | |
| `app/views/evidence/modal_form.rb` | The form rendered into the `#evidence-modal` frame — writing-prompt card (:new/:respond only; role/level line only off the hub), content fields (disabled for a non-author link), and the unified **"Applies to" block**: uniform per-link rows (expectation + required-on-new valence + collapsible examples; entry-point row first + highlighted; last-row remove lock) + the capability/level picker (see *The unified "Applies to" block*) |
| `app/views/evidence/valence.rb` | Shared valence surface vocabulary — UI labels + badge styling for `EvidenceLink::VALENCES` (see *Evidence-link valence*) |
| `app/views/assessments/evidence/link_thread_frame.rb` | One linkage's discussion thread (lazy frame in the evidence card's disclosure) — lifecycle rows + comment cards + composer + removed/withdrawn notices (see *Evidence-linkage discussion threads*) |
| `app/queries/assessments/evidence_link_thread_query.rb` | Assembles a linkage thread — comments + stream-read lifecycle entries (linked / revalenced / removed / withdrawn) |
| `app/controllers/assessments/evidence_link_threads_controller.rb` | `GET /assessments/:id/evidence/:evidence_id/link_thread` — serves the thread frame (comment-policy gated) |
| `app/operations/operations/assessments/set_evidence_link_valence.rb` | Shared web + MCP operation — reclassify one link's valence (`EvidenceLinkRevalenced`; no-op when unchanged) |
| `app/views/evidence/modal_shell.rb` | The bare overlay/panel + lazy `#evidence-modal` frame (plus its `Kit::FrameLoadError` load-failure state), hosted inside `assessment-sync` (so the submit updates the matrix in place) |
| `app/views/evidence/request_modal_shell.rb` | The request-evidence overlay/panel + lazy `#evidence-request-modal` frame + its `Kit::FrameLoadError` state — the modal's own × lives inside the frame, so a failed load without this has no exit at all. Also carries `submit-fallback` + its live region for a transport failure on Send (#316) |
| `app/javascript/controllers/submit_guard_controller.js` | One user action, one request — in-flight lock on the evidence-modal **and request-evidence** submit buttons (see the controllers table) |
| `app/controllers/evidence_modal_controller.rb` | `GET /evidence_modal` — renders `ModalForm` for `(mode, evidence?, request?, cell?)`; resolves permissions + prefill + link options server-side; edit mode loads ALL active links (origin included, entry-point cell first) |
| `app/models/evidence/cell_context_resolver.rb` | Shared per-cell context (name, role, level title, expectation, illustrations) — hub + modal |
| `app/models/evidence/framework_cell_options.rb` | Valid (active + bound + has-expectation) link cells + the per-cell expectation map (incl. role-scoped illustrations) for the "Applies to" rows |
| `app/controllers/concerns/evidence_diff_submit.rb` | Diff-based save — emits the minimal commands (record / update-if-content-changed / add+remove links / respond); links-only never bumps `edited_at` |
| `app/controllers/assessments/evidence_controller.rb#save` | Assessment-surface submit → matrix cell Turbo Streams (hub uses `evidence_requests#respond` / `evidence_items#update`) |
| **CSS** | |
| `app/assets/tailwind/application.css` | `.hero-collapsible` scroll-driven animation (`animation-timeline: scroll(root)`) + `.assessment-scroll-root` anti-shake guard (`overflow-anchor: none` + `min-height` floor — Hard-Won Lesson 16) |
| **Tests** | |
| `test/system/assessments_system_test.rb` | Self-assessment system tests |
| `test/system/manager_assessments_system_test.rb` | Manager assessment system tests |
| `test/system/assessments_activity_feed_focus_system_test.rb` | Activity feed narrows on focus |
| `test/system/assessments_activity_pane_system_test.rb` | Sidebar open/close + responsive behaviour |
| `test/contexts/person_development/scoring_test.rb` | The level-independent scale (ADR-21): components, the per-binding gate, cap window, expectation coverage, `performance_state` transitions |
| `test/components/assessments/hero_summary_test.rb` | Hero copy per state (top of ladder, mastering, blocked, eligible), the components gloss, the 0–200 / 0–100 bar |
| `test/models/assessments/matrix_data_builder_test.rb` | Data shape + `capability_scores_at_next_level` presence |
| `test/system/assessment_delegation_system_test.rb` | Manager grants via modal → delegate reviews + rates → can't start alignment |
| `test/policies/assessment_policy_delegation_test.rb` | Delegate rating, recorded-authoritative manager, grant/revoke gates |
| `test/contexts/person_development/aggregate_authority_test.rb` | Reporting-manager recording, delegation commands, authority guard, `via_delegation` |
| `test/queries/assessments/activity_feed_authority_test.rb` | Delegation/reporting entries, badge, privacy + delegate visibility |

## Keeping This Document Current

Update whenever changes are made to assessment architecture, interaction patterns, component hierarchy, or Stimulus controllers. Specifically:

- **New design decisions** — add with rationale (e.g. new context type, new state in the performance state machine, new threshold)
- **Bug fixes revealing non-obvious behaviour** — add to Hard-Won Lessons
- **New or modified components** — update the File Reference
- **New Stimulus controllers or changed responsibilities** — update the Stimulus controllers table
- **New future extension points** — add; remove entries that have been implemented

If a lesson or decision is superseded, update or remove the old entry rather than appending a contradiction.
