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
- **Suppress for ~900ms after explicit clicks.** Card-header clicks, chip clicks, and any other explicit focus action sets `_capabilityFocusSuppressUntil = Date.now() + 900`. Mirrors the suppression `category_nav_controller#scrollTo` uses for chip clicks — without it, the smooth-scroll animation can fire intersection events that overwrite the user's choice mid-flight.

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
| `category` | Category chip click; scroll-based category active marker | `?category=` | Browser navigation |
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

A horizontal `flex` of `LevelChip`s, one per merged level ordinal. Each chip is colored by frequency × level position (same color rules the old matrix cells used). The person's level chip carries the "YOU" badge and a darker outline when focused. Click dispatches `click->matrix#focusChip`, which sets `?capability=` + `?level_ordinal=`, reloads the matrix frame, and smooth-scrolls the card under both sticky headers (unified + category section).

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
- **Manager** (`context: :manager`) → `ManagerShowView` — manager rates their direct report.
- **Alignment** (`context: :alignment`) → automatic once `cycle status ∈ {aligning, aligned}`. Both parties see all three rating perspectives. There is no opt-in URL param and no in-page toggle.

### Self-assessment privacy

The assessee must not see the manager's rating until alignment formally begins. Enforced at two layers:

1. **Data layer** — `Assessments::MatrixDataBuilder` accepts a `context:` kwarg. When `context == :self`, manager and aligned data are scrubbed from the result — `manager_frequency` / `aligned_frequency` per cell, plus `manager_scoring` / `aligned_scoring` at the top level. The primary scoring perspective is forced to `:self_only`.
2. **Policy layer** — `AssessmentPolicy#view_alignment?` requires the participant's cycle status to be `aligning` or `aligned`. Until the manager has formally started alignment, the assessee renders in `:self` context regardless of any URL params.

### How context flows through components

| Component | What context determines |
|---|---|
| `MatrixDataBuilder` | Which scoring perspective is primary; whether manager/aligned data is scrubbed |
| `HeroSummary` | Which `*_scoring` hash to render (`self_scoring` vs `manager_scoring` vs `aligned_scoring`); subject pronoun ("You're" vs "Alex is") |
| `CapabilityCard` / `LevelChip` | Which `*_frequency` colors the chip; whether divergence dots show |
| `CapabilityCardExpansion` | Which perspective the `FrequencyPill` rates; which `SecondaryRatingLine`s render |
| `FrequencyPill#form_action` | POST endpoint — `/ratings` (self) vs `/manager_ratings` (manager) vs `/alignment_ratings` (alignment) |

## Frequency rating vocabulary

The four rating values share a single palette across every surface — inline pill, level chip, divergent-secondary dot — via `Views::Assessments::FrequencyPalette`. The palette walks a red → orange → amber → green ramp so the four states read as a clear gradient (worse → better) without relying on text. Data values (enum, events, DB, test fixtures) **never** change.

| Enum | Sentence phrase | Compact label | Hue |
|------|----|----|----|
| `none` | Never | None | red |
| `some` | Some of the time | Some | orange |
| `occasional` | Most of the time | Most | amber |
| `consistent` | Consistently | Consistently | green |

The phrase reads inside the inline pill ("…explains reasoning. **Most of the time**"). The compact label is for tight spaces. The hue backs both pill and level chip so the strip and the inline pill agree pixel-for-pixel.

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

| Level position | Frequency | Background |
|---|---|---|
| Below person_level | Unrated | Muted green (assumed consistent) |
| Below person_level | rated | Solid hue from the palette (red / orange / amber / green) |
| At/above person_level | Unrated | Neutral gray |
| At/above person_level | rated | Solid hue from the palette — same fill regardless of level position |

A small **divergence dot** appears on the chip when the primary perspective disagrees with any secondary the viewer can see. Full per-perspective values live in the expansion panel's `SecondaryRatingLine`s.

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

There is **no** `sticky_hero_controller.js`. The hero's collapse is pure CSS scroll-driven animation. See *Hero Summary — Collapse on scroll*.

## Lifecycle

Each enrolled `AssessmentCycleParticipation` walks a lifecycle the views render explicitly:

```text
enrolled → started → aligning → aligned → withdrawn
```

| Status | Trigger | What's editable |
|---|---|---|
| `enrolled` | `PersonEnrolled` lands | Self + manager ratings |
| `started` | First `SelfRated` / `ManagerRated` event with `source: "human"` | Self + manager ratings |
| `aligning` | Manager fires `AlignmentStarted` | Aligned values only — self + manager FROZEN |
| `aligned` | Manager fires `FullAlignmentCompleted` | Nothing — all ratings frozen |
| `withdrawn` | Person unenrolled or cycle closed | Nothing |

**Threading the status to the views.** `MatrixDataBuilder` reads `participant_status` and produces two boolean flags:

- `individual_ratings_frozen` — true for `aligning` / `aligned`. Threaded through `CapabilityCardExpansion` as `frozen:`. In self/manager context, the primary `FrequencyPill` renders as a static (non-interactive) coloured span instead of an interactive trigger.
- `alignment_locked` — true only for `aligned`. Threaded as `alignment_locked:`. In alignment context, the alignment selector also becomes a read-only bar.

Both flags also flow through the rating controllers' Turbo Stream responses so post-event re-renders pick the correct read-only / interactive shape.

**Header layout.** Both `ShowView` and `ManagerShowView` render a single-row header (`flex flex-wrap items-baseline gap-x-3 gap-y-1`):

- **Self view** — H1 is the level title; shortcode chip is `"#{role.code}#{level.ordinal}"`; status pill (`In Progress` / `Aligning` / `Aligned`) when a cycle is open.
- **Manager view** — H1 is `assessee.name`; subtitle span renders the level title; same shortcode + status pill.

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
| `app/views/assessments/level_chip.rb` | One chip per level — color by frequency × level position, YOU badge, divergence dot |
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
| **Controllers** | |
| `app/controllers/assessments_controller.rb` | show / index / matrix / scoring / activity — self/manager/alignment context routing |
| `app/controllers/assessments/ratings_controller.rb` | Self-rating POST (rate_self, revise, clear) |
| `app/controllers/assessments/manager_ratings_controller.rb` | Manager-rating POST (rate_as_manager, revise, clear) |
| `app/controllers/assessments/alignment_ratings_controller.rb` | Per-cell alignment POST (align_assessment) |
| `app/controllers/assessments/alignment_starts_controller.rb` | Manager-only POST — fires `AlignmentStarted`, locks individual ratings |
| `app/controllers/assessments/alignment_completions_controller.rb` | Manager-only POST — fires `FullAlignmentCompleted`, freezes all ratings |
| **Data** | |
| `app/models/assessments/matrix_data_builder.rb` | Single-role builder — ratings + 4 scoring perspectives + `performance_state` + next-level contributions |
| `app/read_models/assessment_level_rating.rb` | Three-frequency read model (self / manager / aligned) |
| `app/read_models/person_framework_assignment.rb` | Person-framework-role-level assignment |
| **JavaScript** | |
| `app/javascript/controllers/matrix_controller.js` | Chip-click focus, smooth-scroll, URL sync, sibling dimming (shared with framework explorer) |
| `app/javascript/controllers/category_nav_controller.js` | `--sticky-header-h` publish, chip-click scroll, active-chip detection on scroll |
| `app/javascript/controllers/assessment_sync_controller.js` | ActionCable sync, self-submit suppression, dual-frame reload, focus-param merge |
| `app/javascript/controllers/frequency_selector_controller.js` | Optimistic frequency button UI |
| `app/javascript/controllers/activity_feed_controller.js` | Focus-narrowing on `matrix:focus-changed` |
| `app/javascript/controllers/continue_assessing_controller.js` | Bottom-line CTA — dispatches focus-unrated event |
| **CSS** | |
| `app/assets/tailwind/application.css` | `.hero-collapsible` scroll-driven animation (`animation-timeline: scroll(root)`) |
| **Tests** | |
| `test/system/assessments_system_test.rb` | Self-assessment system tests |
| `test/system/manager_assessments_system_test.rb` | Manager assessment system tests |
| `test/system/assessments_activity_feed_focus_system_test.rb` | Activity feed narrows on focus |
| `test/system/assessments_activity_pane_system_test.rb` | Sidebar open/close + responsive behaviour |
| `test/contexts/person_development/scoring_test.rb` | `performance_state` transition-point coverage; raw_contribution math |
| `test/models/assessments/matrix_data_builder_test.rb` | Data shape + `capability_contributions_at_next_level` presence |

## Keeping This Document Current

Update whenever changes are made to assessment architecture, interaction patterns, component hierarchy, or Stimulus controllers. Specifically:

- **New design decisions** — add with rationale (e.g. new context type, new state in the performance state machine, new threshold)
- **Bug fixes revealing non-obvious behaviour** — add to Hard-Won Lessons
- **New or modified components** — update the File Reference
- **New Stimulus controllers or changed responsibilities** — update the Stimulus controllers table
- **New future extension points** — add; remove entries that have been implemented

If a lesson or decision is superseded, update or remove the old entry rather than appending a contradiction.
