# Assessment UX — Design & Architecture

This document captures the design decisions, interaction patterns, and hard-won lessons from building the assessment views (self-assessment, manager assessment, and alignment). Consult this before modifying assessment UX or building features that extend it.

> **See also:** [scoring-model.md](../architecture/scoring-model.md) for the scoring engine, performance-state vocabulary, and configurable thresholds.

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
Browser:      /assessments/:id?category=<category_id>&capability=<stable_id>&level_ordinal=<n>
Matrix frame: /assessments/:id/matrix?category=<category_id>&capability=<stable_id>&level_ordinal=<n>
Activity:     /assessments/:id/activity?capability=<stable_id>&level_ordinal=<n>
```

- `category` absent → server defaults to the first category for highlighting in the chip bar; all categories still render in the document.
- `capability` is the capability's **stable_id** (cross-version UUID), never the per-version `capability_id`.
- `level_ordinal` only honoured when `capability` is also present.
- Every capability card auto-focuses the person's current level on render (the expansion panel is always visible for `@person_level`). When the URL specifies `?capability=` + `?level_ordinal=`, that overrides — the named card's expansion panel renders for the requested level instead.
- `matrix_controller#syncFocusToUrl` writes `capability` and `level_ordinal` together in **one** `history.pushState` per focus change, so Back/Forward maps 1:1 to visible focus changes.
- Category chip clicks update the URL with `?category=` and dispatch a `matrix:focus-changed` event at category level so the activity feed narrows.

## Hero Summary — three bands

The hero is a single card with three logical bands. The header and bottom line are always visible; only the middle band scrolls away.

```
┌─ #scoring-panel ───────────────────────────────────────────────┐
│  ── Hero header (always visible) ─────────────────────────────│
│  Verdict headline           91%       ← big number on the     │
│  Gloss · L2 expectations    of expected                       │
│  [Promo pill] [Continue →]  ▓▓▓░░░    ← bar + bottom line     │
│                                          stack in left col    │
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
- Later: `COVERAGE_UNLOCK_THRESHOLD` could become framework-configurable like the other scoring thresholds.

### Header band

The left column carries the verdict headline, a one-line gloss, and the "bottom line" (promotion pill + Continue CTA). The right column carries the big percentage + "of expected" caption + a thin progress bar. Both columns sit side-by-side so the card is just tall enough to fit whichever side is taller — the previous "stack vertically" layout wasted ~40px below the big number.

The Continue CTA is intentionally small (chip-sized, `text-[11px] px-2 py-0.5`) so it sits inline with the promotion pill instead of looking like a primary action — at the hero level, it's a *nudge*, not the main affordance.

### Middle band — state-driven

A **single** panel framed by `performance_state`. The state picks the headline, tone, and list of capabilities. There is no separate Strengths vs Lift column — that doubled up the story. The state is the headline; the capabilities are the *evidence* for it.

| Performance state | Headline | List label | Items | Border |
|---|---|---|---|---|
| `:underperforming` | "Underperforming at E(n)" | "Gap to E(n)" | 3 lowest current-level contributions | red |
| `:progressing` | "Progressing toward E(n)" | "Gap to E(n)" | 3 lowest current-level contributions | amber |
| `:performing` | "Performing at E(n)" | "Gap to mastering" | 3 lowest **next-level** contributions | blue |
| `:mastering` | "Mastering E(n)" | "Gap to promotion to E(n+1)" | blocked-at-next-level or 3 lowest next-level contributions | purple |
| `:eligible` | "Eligible for promotion to E(n+1)" | "Top contributors" | 3 highest current-level contributions | green |

**Key insight — always point at the next milestone, never one already cleared.** A `:performing` person isn't trying to *meet* their level (they already do); they're trying to *master* it. A `:mastering` person isn't trying to master (they already do); they're trying to be eligible for promotion. The Gap-to label reflects this — and crucially, `:performing` uses **next-level** contributions, not current-level, because mastery is earned by overperformance at the level above.

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

## Category navigation

Five surfaces, all reading from the same `?category=` URL state:

1. **Chip bar** in the sticky header. Anchor links to `#category-<id>`. Active chip has `aria-current="page"` and a dark fill. Click is intercepted by `category_nav_controller#scrollTo` (smooth-scrolls, accounting for sticky header height) and pushes the new `?category=` to the URL.
2. **Category sections** in the main column. Each `<section id="category-<id>">` has a sticky inner heading that pins just under the unified header at `top: var(--sticky-header-h)`. `category_nav_controller#publishHeaderHeight` measures the unified header with `getBoundingClientRect().height` (sub-pixel precision) and writes it to a CSS custom property via `ResizeObserver`.
3. **Scroll-based active marker**. As the user scrolls, `category_nav_controller#updateActiveCategory` finds the deepest section whose top has scrolled past the threshold and marks its chip active. Suppressed for ~900ms after a chip click so the explicit click result survives the smooth-scroll animation (otherwise the final scroll event of the animation could fall short of the threshold and re-mark the previous chip).
4. **Activity sidebar**. Listens for `matrix:focus-changed@window` with `level: "category"` and narrows its rendered entries.
5. **Server state**. The controller reads `?category=` only to render the active chip class — the document includes every category section regardless.

## Capability focus

Sits between category focus and cell focus in the focus hierarchy. Narrows the activity sidebar to a single capability without committing to a specific level (the latter is cell focus, set by chip click).

Two ways to trigger it:

**Card-header click.** Clicking the card's header region (eyebrow + capability name + description) sets capability focus. Wired with `data-action="click->matrix#focusCapability"` scoped to the header (not the whole card) so clicks on the level strip and inside the expansion panel — which carry their own focus and interactive affordances — never accidentally land here. Re-clicking the same focused card's header toggles back to category focus, mirroring `focusCategory`'s behaviour.

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
│   [None] [Some] [Most] [Consistently]                      │
│   EXAMPLES (illustrations for this level)                  │
│   EVIDENCE  +                                              │
│   COMMENTS  +                                              │
└────────────────────────────────────────────────────────────┘
```

Structure: `card_header` (eyebrow + name + signed delta + add-evidence) + `LevelStrip` + `CapabilityCardExpansion` for the focused level.

### Auto-focus on the person's level

Every card auto-focuses the person's current level on first render — the expansion panel is *always* visible for `@person_level`. When `?capability=` + `?level_ordinal=` are present in the URL, the named card uses that level instead. There is no longer a "default" state with the strip but no panel.

There is no `×` close button. The previous design had one to drop back to "no level focused"; with auto-focus there's nothing meaningful to close *to*. Re-focusing means clicking a different level chip — handled by `matrix_controller#focusChip`, which sets the URL and reloads the matrix frame.

### Signed contribution delta

The top-right of every card carries the capability's **signed score delta** (e.g. `+0.5`, `-0.5`, `+0.0`) — the raw value from `Scoring#raw_contribution`. Color-tiered:

| Value | Color |
|---|---|
| ≥ +0.5 | green |
| -0.5 .. +0.5 | neutral gray |
| -1.5 .. -0.5 | amber |
| ≤ -1.5 | red |

The previous design rendered this as a percentage AND hid the badge entirely when contribution was negative — silently dropping the most informative signal. Don't reintroduce either.

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
- **Manager** (`context: :manager`) → `ManagerShowView` — manager rates their direct report. **An active rating delegate gets this same view** (`manager_viewing?` is true for them), so they review and rate exactly like the manager — minus the alignment actions.
- **Alignment** (`context: :alignment`) → automatic once `cycle status ∈ {aligning, aligned}`. Both parties see all three rating perspectives. A delegate sees alignment **read-only** (`view_alignment?` includes active delegates) but can never record/start/complete it. There is no opt-in URL param and no in-page toggle.

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

## Frequency rating vocabulary

The four rating values share a single palette across every surface — inline pill, level chip, divergent-secondary dot — via `Views::Assessments::FrequencyPalette`. The palette uses a red → yellow → green → blue scale: four **maximally-distinct hues** so adjacent states never blur. This replaced the old red → orange → amber → green ramp, whose middle two (orange "Some" vs amber "Most") were near-indistinguishable on small chips — and unusable in a diagonal split (see *Level chip coloring*). Data values (enum, events, DB, test fixtures) **never** change.

| Enum | Sentence phrase | Compact label | Hue |
|------|----|----|----|
| `none` | Never | None | red |
| `some` | Some of the time | Some | yellow |
| `occasional` | Most of the time | Most | green |
| `consistent` | Consistently | Consistently | blue |

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

— a coloured dot from the same palette plus a sentence. Replaces the previous `FrequencyBar` (filled progress bar that duplicated the text label).

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

When two perspectives the viewer can see **disagree**, the chip paints a **diagonal split** instead of a solid fill: a `/` seam from bottom-left to top-right, with the **primary perspective in the top-left triangle** (the customary slot) and the diverging secondary bottom-right. Per context: manager view → **manager top-left, self bottom-right**; alignment (while unresolved) → **self top-left, manager bottom-right** (reading order, since the primary `aligned` value isn't set yet). Implemented as a base fill (the bottom-right colour) plus an absolute clip-path overlay (the top-left colour); the centered level code gets an opaque backing so it stays legible across the seam. A `data-split="true"` hook on the overlay supports testing.

- **Why a split, not a coloured dot:** the *seam itself* is a shape signal — a split chip reads as "contested" regardless of the two colours, so it survives colour-blindness and the colours-too-close trap. It also shows *both values* in place.
- **Partial ratings split too:** when one perspective has rated and the other hasn't, the chip splits the rated colour against the missing slice — so "I rated, they haven't" doesn't masquerade as a mutual solid fill. The missing slice's colour depends on level: **at/above** the person's level it paints **grey** (genuinely unrated); **below** the person's level it paints the **assumed-consistent blue** (`blue-300`), the same default the solo chip and scoring use for a below-level cell, rather than grey — a grey slice there would wrongly read as "no rating" when the system in fact assumes consistency. The assumed default only fills a slice whose *counterpart was rated*; a below-level cell with neither perspective rated stays the lighter solo `blue-300` tint via the unrated branch. Crucially, an explicit `consistent` (solid `blue-500`) still **splits** against an assumed-consistent default (`blue-300`) — the two agree on the value but differ in explicit-vs-assumed, so both blue shades show in their perspective positions rather than collapsing to one fill. The chip renders solid only when both slices are *explicitly* rated and equal (or in a single-perspective context).
- **Per context:** `:self` never splits (only one perspective visible). `:manager` splits on self-vs-manager. `:alignment` splits on self-vs-manager **until a recorded aligned value resolves the cell to a solid** — so a contested cell visibly snaps solid as you record agreement (this also fixed the old "both rated but the chip is grey" bug, since the aligned value was empty pre-resolution).

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

Every perspective hash now carries a `performance_state` symbol (see [scoring-model.md](../architecture/scoring-model.md)) and, when the person isn't at the top of the level ladder, a `capability_contributions_at_next_level` map keyed by stable_id. The hero's middle band uses both to pick its narrative — see *State-driven panel* above.

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
alignment milestones, comments, and **all evidence actions** — recording,
editing, withdrawing, **and link add / remove** (`evidence_linked` /
`evidence_unlinked`). When you add a new assessment action, you add its feed
entry in the same change:

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
`CurrentAssessment` (ratings / alignment), `EvidenceCollection` (evidence +
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

**The rater's own broadcast echo is suppressed.** `assessment_sync_controller#listenForOwnSubmits` arms a 5-second `_suppressReloadUntil` window on the EARLIEST signal of a user-initiated form submit — `pointerdown` / `mousedown` / `click` (capture phase) against any real submit control (`button[type='submit']`, default-type `<button>` inside a form, `input[type='submit']`), plus `turbo:submit-start` as a backstop for programmatic submits. The MutationObserver bails when within the window so the rater's own broadcast doesn't trigger a redundant frame reload (flicker + scroll reset).

**Focus-param merge on reload.** `#mergeFocusParams` reads `?capability=` + `?level_ordinal=` from the BROWSER URL and stamps them onto the matrix frame's `src` before reload, so focus survives broadcast-driven frame reloads.

## Stimulus controllers

| Controller | Responsibility |
|---|---|
| `matrix_controller.js` | Chip-click focus, card-header click focus (capability), scroll-driven capability focus via IntersectionObserver, smooth-scroll-under-sticky-headers, URL sync (`?capability=` + `?level_ordinal=`), URL-first focus restoration on connect, `data-focused` stamping on cards, sibling card dimming when a card is URL-focused. Shared with the framework explorer (table-mode methods live there). |
| `category_nav_controller.js` | Publishes `--sticky-header-h` via `getBoundingClientRect().height` + `Math.ceil` + `ResizeObserver`. Smooth-scrolls to category sections on chip click. Updates the active chip on scroll (suppressed for 900ms after a chip click — see *Category navigation*). |
| `assessment_sync_controller.js` | ActionCable sync, self-submit suppression window, dual-frame reload, focus-param merge before reload. |
| `frequency_selector_controller.js` | Optimistic UI on rating button click. Form action lives in the view, not the controller. |
| `activity_feed_controller.js` | Listens for `matrix:focus-changed` and narrows entries by capability + level focus. |
| `context_pane_controller.js` (shared with framework explorer) | Right-pane suggestion / activity panel state, URL focus sync. |
| `continue_assessing_controller.js` | Bottom-line CTA — dispatches a window event with the next-unrated capability stable_id + level, picked up by `matrix_controller#focusUnrated`. |
| `modal_controller.js` | Generic `Kit::Modal` controller — open/close, Esc, body-scroll-lock. **Outside-click dismissal is opt-in** (`dismissOnOutsideClick` value, default off) so a stray background click can't discard a half-filled transactional form — modals close via the × button, Cancel, Esc, or a successful submit. Hosts the Delegates modal (standalone) and the unified evidence modal (embedded — a lazy `#evidence-modal` frame). |
| `evidence_modal_controller.js` | Drives the **unified evidence modal** (one modal for new/edit/respond, both surfaces). The page instance's `load` sets the lazy `#evidence-modal` frame `src` from a trigger's action params (mode + ids + `return_to`), so the server renders the right form each open; the in-frame instance toggles the custom-type label and manages the "also applies to" link rows (each showing that cell's behavioural expectation, read from an embedded JSON map). Replaced the old `evidence_form` / `evidence_edit_form` / `evidence_link_form` / `evidence_response` controllers. |

There is **no** `sticky_hero_controller.js`. The hero's collapse is pure CSS scroll-driven animation. See *Hero Summary — Collapse on scroll*.

## Lifecycle

Each enrolled `AssessmentCycleParticipation` walks a lifecycle the views render explicitly:

```text
enrolled → started → aligning → aligned → withdrawn
```

| Status | Trigger | What's editable |
|---|---|---|
| `enrolled` | `PersonEnrolled` lands | Self + manager ratings (incl. delegate) |
| `started` | First `SelfRated` / `ManagerRated` event with `source: "human"` | Self + manager ratings (incl. delegate) |
| `aligning` | Manager fires `AlignmentStarted` | Aligned values only — self + manager FROZEN |
| `aligned` | Manager fires `FullAlignmentCompleted` | Nothing — all ratings frozen |
| `withdrawn` | Person unenrolled or cycle closed | Nothing |

**Threading the status to the views.** `MatrixDataBuilder` reads `participant_status` and produces two boolean flags:

- `individual_ratings_frozen` — true for `aligning` / `aligned`. Threaded through `CapabilityCardExpansion` as `frozen:`. In self/manager context, the primary `FrequencyPill` renders as a static (non-interactive) coloured span instead of an interactive trigger.
- `alignment_locked` — true only for `aligned`. Threaded as `alignment_locked:`. In alignment context, the alignment selector also becomes a read-only bar.

Both flags also flow through the rating controllers' Turbo Stream responses so post-event re-renders pick the correct read-only / interactive shape.

**Header layout.** Both `ShowView` and `ManagerShowView` render a single-row header (`flex flex-wrap items-baseline gap-x-3 gap-y-1`):

- **Self view** — H1 is the level title; shortcode chip is `"#{role.code}#{level.ordinal}"`; status pill (`In Progress` / `Assessment Complete` / `Aligning` / `Aligned`) when a cycle is open.
- **Manager view** — H1 is `assessee.name`; subtitle span renders the level title; same shortcode + status pill.

**Status pill** (`Views::Assessments::StatusPill`, wrapped in `id="assessment-status-pill"` for Turbo replacement; the two header layouts share it via `HeaderChrome#render_status_pill`). The pill rewards finishing the current-level ratings *before* the manager-driven alignment phase: while a cycle is open and the participant is pre-alignment, it reads **"In Progress"** (amber) until **current-level coverage hits 100%** in the viewer's perspective, then **"Assessment Complete"** (green). "Complete" is `MatrixDataBuilder#current_level_complete?` — every capability with a cell at `person_level` rated under the context's primary frequency (self ratings for `:self`, manager for `:manager`); a role with no current-level cells is never complete. Because the pill lives in the static header (outside the scoring/matrix Turbo Frames), the self and manager rating controllers `turbo_stream.replace` it on every rating change so it flips live the moment the final cell is rated — no reload. `aligning`/`aligned` still win and show "Aligning"/"Aligned".

**Assessments list — dual-party status.** The `/assessments` list ([index_view.rb](../../app/views/assessments/index_view.rb)) represents both parties. A **Team Assessments** (report) card shows a **Self** chip and a **Manager** chip, each `Not started` / `In progress` / `Complete`; when both are complete it adds a quiet "Ready to align" cue. A person's **own** card shows the **Self** chip only — the manager's progress stays private until alignment (privacy gate). Once alignment starts, a single `Aligning` / `Aligned` chip replaces the per-side chips. "Complete" here is the **same current-level-coverage notion** as the header pill, so the Manager sub-badge and the report's "Assessment Complete" pill always agree.

The per-side `Complete` is a **projected, event-sourced fact**: [`CurrentAssessment`](../../app/contexts/person_development/projections/current_assessment.rb) runs [`Assessments::LevelCoverage`](../../app/queries/assessments/level_coverage.rb) on every rating change and stamps `assessment_cycle_progress.self_completed_at` / `manager_completed_at` (original completion time preserved across edits that stay complete; cleared when coverage drops). `status` stays the lifecycle phase — the two sides complete independently, so completion can't live in a single enum. The index reads those timestamps plus one cheap "any rating per side" query for the `Not started` vs `In progress` distinction (which needs no framework structure). `LevelCoverage`'s denominator mirrors `MatrixDataBuilder` exactly (active, role-bound capabilities with an expectation at the assessed level), pinned by a test. Known limitation: a `FrameworkVersionMigrated` that changes the current-level cell set without a subsequent rating can leave a stale flag until the next rating.

**Action cluster (right side).** Manager view with status `started` shows "Start alignment" (form with `data-turbo-confirm`); status `aligning` shows "Mark alignment complete". Status `aligning` or `aligned` automatically renders in alignment mode — no toggle.

**`AlignmentStartsController` / `AlignmentCompletionsController`** dispatch the lifecycle commands and redirect back to `assessment_path(@assignment)`. Both rescue `RuntimeError` from the aggregate to surface a generic flash alert.

**Auto-alignment on start.** Inside the same RES transaction as `AlignmentStarted`, `PersonDevelopment::CommandHandler#start_alignment` emits an `AssessmentAligned` event for every (capability × level) cell where both `self_rated_frequency` and `manager_rated_frequency` are explicitly recorded **and equal**. The conversation in alignment mode then focuses on disagreements and unrated cells. Default-fallback agreements are NOT auto-aligned. Auto-aligned events carry the comment "Auto-aligned: self and manager already agreed".

**Cross-cycle seeding.** When a person enrols in a new cycle for a framework where they previously completed alignment, both their self and manager ratings are pre-populated from the prior cycle's `aligned_frequency`. The seeded events carry `source: "seeded"` (vs the default `"human"`) and `seeded_from_cycle_id`. The participant stays in `enrolled` until the user makes their first real edit — seeded events alone do not trigger `started`.

## Hard-Won Lessons

### 1. Separate view hierarchies over multi-mode components

A parallel `app/views/assessments/` hierarchy with its own card/strip/chip components was cleaner than adding mode parameters to the framework explorer's view. Assessment components need frequency selectors, secondary bars, contribution badges, and color-tiered chip backgrounds that don't belong in the read-only explorer.

### 2. Context threading must be end-to-end

The `:self` / `:manager` / `:alignment` context flows from controller detection through the builder, into every view component, and into form action URLs. Missing the context at any layer — especially `FrequencyPill#form_action` — routes ratings to the wrong endpoint silently.

### 3. Perspective scoring returns nil, not empty

`build_perspective_scoring` returns `nil` (not an empty hash) when no ratings exist for a perspective. `HeroSummary` falls back to effective scoring when its preferred perspective is nil. Returning an empty hash would display misleading zero scores.

### 4. The middle band must point at the *next* milestone, not one already cleared

At 110% performance ratio (in `:performing` range 0.95–1.15), the original state machine fired `:progressing_to_next` because next-level ratio was above the underperforming floor. That's wrong UX — the person hasn't even mastered current yet. The mental model the user wanted was *always-the-next-gate*: focus on mastering current first, then on promotion. The state machine now drops `:progressing_to_next` entirely; `:performing` owns the 0.95–1.15 band and is framed as "Gap to mastering", using next-level contributions so the gap values actually mean something (capabilities at `+0.0` current would show `-1.0` at L+1 — the real signal).

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

## Performance state machine

Defined in `PersonDevelopment::Scoring#performance_state`. See [scoring-model.md](../architecture/scoring-model.md) for the canonical definition. Summary:

```
:underperforming  ratio < underperforming_threshold (default 0.80)
:progressing      underperforming_threshold ≤ ratio < meeting_threshold
                  OR any capability blocked
:eligible         has_next_level AND promotion_readiness[:eligible]
:mastering        ratio ≥ mastery_threshold AND not eligible
:performing       otherwise (meeting_threshold ≤ ratio < mastery_threshold)
```

Precedence: underperforming → progressing → eligible → mastering → performing.

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
| `app/views/assessments/status_pill.rb` | Header status pill — In Progress / Assessment Complete / Aligning / Aligned; Turbo-replaceable (`id="assessment-status-pill"`) |
| `app/views/assessments/header_chrome.rb` | Shared header chrome (shortcode chip + `render_status_pill`) for both show views |
| **Hero summary** | |
| `app/views/assessments/hero_summary.rb` | Three-band hero card with state-driven middle band; renders inside the unified sticky header |
| **Category navigation** | |
| `app/views/assessments/category_chip_bar.rb` | Sticky chip row, active marker, scoring legend |
| `app/views/assessments/category_section.rb` | Anchor target + sticky section heading + stack of capability cards |
| **Matrix content** | |
| `app/views/assessments/assessment_matrix_frame_view.rb` | Turbo Frame wrapper for the matrix |
| `app/views/assessments/assessment_matrix.rb` | Container that renders each `CategorySection` |
| `app/views/assessments/capability_card.rb` | One card per capability — eyebrow, name, signed delta, level strip, expansion panel |
| `app/views/assessments/level_strip.rb` | Horizontal flex of `LevelChip`s, scrolls horizontally on narrow |
| `app/views/assessments/level_chip.rb` | One chip per level — solid fill by frequency, diagonal split on disagreement / partial rating (colour vs grey), evidence/comment glyphs, YOU/CURRENT current-level badge |
| `app/views/assessments/capability_card_expansion.rb` | Focused-level panel — expectation sentence + inline FrequencyPill, divergent SecondaryRatingLines, illustrations, evidence, comments |
| `app/views/assessments/frequency_palette.rb` | Shared 4-state colour palette + sentence phrases for pill / chip / dot |
| `app/views/assessments/frequency_pill.rb` | Inline rating pill (interactive popover or static coloured span) |
| `app/views/assessments/secondary_rating_line.rb` | Divergent-perspective sentence with a colour-coded dot |
| `app/views/assessments/frequency_selector.rb` | Four-button rating control (context determines POST endpoint) |
| `app/views/assessments/frequency_bar.rb` | Read-only secondary rating bar with divergence dot |
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
| **Data** | |
| `app/models/assessments/matrix_data_builder.rb` | Single-role builder — ratings + 4 scoring perspectives + `performance_state` + next-level contributions + `current_level_complete`. Resolves the **assessed level** from the cycle's enrollment snapshot (same-role gate), not the live assignment level — see [ADR-19](../architecture/adrs.md) |
| `app/queries/assessments/level_coverage.rb` | Current-level self/manager completion for a (person, framework, cycle). Mirrors the builder's denominator; consumed by the `CurrentAssessment` projection to stamp `assessment_cycle_progress.{self,manager}_completed_at` for the dual-party list status |
| `app/read_models/assessment_level_rating.rb` | Three-frequency read model (self / manager / aligned) |
| `app/read_models/person_framework_assignment.rb` | Person-framework-role-level assignment |
| `app/read_models/recorded_reporting_manager.rb` | Recorded reporting manager — authoritative for manager-rating authority |
| `app/read_models/manager_assessment_delegation.rb` | Active/revoked rating delegations; `active` scope + `candidate_people` |
| **JavaScript** | |
| `app/javascript/controllers/matrix_controller.js` | Chip-click focus, smooth-scroll, URL sync, sibling dimming (shared with framework explorer) |
| `app/javascript/controllers/category_nav_controller.js` | `--sticky-header-h` publish, chip-click scroll, active-chip detection on scroll |
| `app/javascript/controllers/assessment_sync_controller.js` | ActionCable sync, self-submit suppression, dual-frame reload, focus-param merge |
| `app/javascript/controllers/frequency_selector_controller.js` | Optimistic frequency button UI |
| `app/javascript/controllers/activity_feed_controller.js` | Focus-narrowing on `matrix:focus-changed` |
| `app/javascript/controllers/continue_assessing_controller.js` | Bottom-line CTA — dispatches focus-unrated event |
| `app/javascript/controllers/modal_controller.js` | Generic `Kit::Modal` open/close/Esc; opt-in outside-click dismissal (`dismissOnOutsideClick`, default off); dispatches `modal:open` |
| `app/javascript/controllers/evidence_modal_controller.js` | Drives the unified evidence modal — frame `load`, link rows, type toggle (shared with the hub) |
| **Unified evidence modal** (one modal for new/edit/respond, assessment + hub) | |
| `app/views/evidence/modal_form.rb` | The form rendered into the `#evidence-modal` frame — context-aware primary block (expectation + examples; role/level line only off the hub), content fields (disabled for a non-author link), "also applies to" picker with per-cell expectations |
| `app/views/evidence/modal_shell.rb` | The bare overlay/panel + lazy `#evidence-modal` frame, hosted inside `assessment-sync` (so the submit updates the matrix in place) |
| `app/controllers/evidence_modal_controller.rb` | `GET /evidence_modal` — renders `ModalForm` for `(mode, evidence?, request?, cell?)`; resolves permissions + prefill + link options server-side |
| `app/models/evidence/cell_context_resolver.rb` | Shared per-cell context (name, role, level title, expectation, illustrations) — hub + modal |
| `app/models/evidence/framework_cell_options.rb` | Valid (active + bound + has-expectation) link cells + the per-cell expectation map for the picker |
| `app/controllers/concerns/evidence_diff_submit.rb` | Diff-based save — emits the minimal commands (record / update-if-content-changed / add+remove links / respond); links-only never bumps `edited_at` |
| `app/controllers/assessments/evidence_controller.rb#save` | Assessment-surface submit → matrix cell Turbo Streams (hub uses `evidence_requests#respond` / `evidence_items#update`) |
| **CSS** | |
| `app/assets/tailwind/application.css` | `.hero-collapsible` scroll-driven animation (`animation-timeline: scroll(root)`) + `.assessment-scroll-root` anti-shake guard (`overflow-anchor: none` + `min-height` floor — Hard-Won Lesson 16) |
| **Tests** | |
| `test/system/assessments_system_test.rb` | Self-assessment system tests |
| `test/system/manager_assessments_system_test.rb` | Manager assessment system tests |
| `test/system/assessments_activity_feed_focus_system_test.rb` | Activity feed narrows on focus |
| `test/system/assessments_activity_pane_system_test.rb` | Sidebar open/close + responsive behaviour |
| `test/contexts/person_development/scoring_test.rb` | `performance_state` transition-point coverage; raw_contribution math |
| `test/models/assessments/matrix_data_builder_test.rb` | Data shape + `capability_contributions_at_next_level` presence |
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
