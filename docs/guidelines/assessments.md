# Assessment UX — Design & Architecture

This document captures the design decisions, interaction patterns, and hard-won lessons from building the assessment views (self-assessment, manager assessment, and alignment). Consult this before modifying assessment UX or building features that extend it.

> **See also:** [scoring-model.md](../architecture/scoring-model.md) for the scoring engine, performance-state vocabulary, and configurable thresholds.

> **Terminology — "Feedback / Evidence" on the surface, "evidence" in the domain.** User testing showed the bare word "evidence" discouraged people from contributing constructive feedback, so the **user-facing UI and the MCP tool descriptions** call this concept **"Feedback / Evidence"** (prominent labels, nav, headings, modal titles) or **"feedback"** (running prose, flashes, activity-feed sentences, notifications). The **domain vocabulary is unchanged**: events, commands, handlers, read models (`EvidenceItem`, `EvidenceRequest`, `EvidenceLink`), DB columns, form param namespaces (`evidence[...]`), routes (`/evidence`), Stimulus controllers (`evidence-modal`, `request-evidence`), turbo-frame ids, the `data-glyph="evidence"` attribute, activity `KIND_GROUP`/kind values (`evidence_recorded`…), and the MCP **tool names** (`assessments_record_evidence`…) all stay "evidence". The relabel is presentational only — no migration or projection rebuild. When adding a surface, follow the same split: label it "Feedback / Evidence", keep the identifier "evidence".

## Where everything lives

This guide is the entry point; it loads whenever you open a file under `app/views/assessments/` or `app/controllers/assessments/`. The rest is split by concern so that loading it stays cheap. Section names and lesson numbers are unchanged from the single-file guide, so a reference like "assessments.md → Role-scoped reads" still finds its target through this table.

| Read | When you are about to… | Holds |
|---|---|---|
| this file | change anything on the assessment screens | Overview, category navigation, capability focus and cards, context-driven rendering (incl. self-assessment privacy), the frequency vocabulary, level chips, activity feed coverage, real-time sync |
| [scoring.md](assessments/scoring.md) | change the hero, the score's wording or definitions, "How is this calculated?", or which perspective a page scores | Hero Summary, The explanation layer (incl. the glossary's copy rules), Multi-perspective scoring, Performance state machine |
| [role-lens.md](assessments/role-lens.md) | read or rate against another role or level, or write any query over ratings | Role lens, incl. **Role-scoped reads**, per-role alignment, declared exploration |
| [lifecycle.md](assessments/lifecycle.md) | change what a status allows, alignment milestones, carry-forward seeding or delegation | Manager-rating delegation, Lifecycle (incl. auto-alignment on start and cross-cycle seeding / carry-forward) |
| [evidence.md](assessments/evidence.md) | change recording, linking or requesting feedback / evidence, or comment notifications | Evidence-link valence, linkage threads, the "Applies to" block, proactive feedback, requesting evidence, comment notifications |
| [stimulus-controllers.md](assessments/stimulus-controllers.md) | change a Stimulus controller the assessment screens use | Stimulus controllers |
| [lessons.md](assessments/lessons.md) | touch anything a lesson below names | Hard-Won Lessons 1–20 |
| [file-reference.md](assessments/file-reference.md) | look for the file that owns something | File Reference |

### Hard-Won Lessons — index

Each title is the rule. Read the lesson in [lessons.md](assessments/lessons.md) before changing what it names.

- **1.** Separate view hierarchies over multi-mode components
- **2.** Context threading must be end-to-end
- **3.** Perspective scoring returns nil, not empty
- **4.** The middle band must point at the *next* milestone, not one already cleared
- **5.** CSS scroll-driven animation needs `grid-template-rows`, not `max-height`
- **6.** Sub-pixel rounding leaves a 1px gap under the sticky header
- **7.** Active-chip detection must be locked during programmatic scroll
- **8.** Capability contribution must render as a signed delta, never hidden when negative
- **9.** Auto-focus removes the "no level focused" state — drop the close button with it
- **10.** Rating Turbo Streams must re-render with the right mode + context
- **11.** IntersectionObserver's connect-time callback isn't a user scroll
- **11a.** "Deepest card past the sticky chrome" is symmetric in mechanism but asymmetric in perception
- **12.** Activity feed reconnect on lazy-frame load needs a DOM signal for capability focus
- **13.** Renew-on-scroll suppression beats a fixed time window
- **14.** IntersectionObserver callbacks aren't load-bearing for the picker
- **15.** External category focus must be sticky against the scroll picker
- **16.** A scroll-driven animation that resizes an in-flow element shakes — two couplings, two fixes
- **17.** Toggling Tailwind `hidden` on an element that already has a `display` utility doesn't hide it
- **18.** Per-card selected level needs its own *rendering* axis, separate from the single *focus* axis
- **19.** A sticky pane under a moving header can't be sized by CSS alone
- **20.** A swapped card is a new node — never remember a card by its element

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
- `matrix_controller#syncFocusToUrl` writes `capability` and `level_ordinal` together in **one** `history.pushState` per focus change, so Back/Forward maps 1:1 to visible focus changes. A chip click also merges `levels[<stable_id>]=<ordinal>` into the browser URL (accumulating). **The browser URL is the map's source of truth**: a chip click swaps one card without touching the matrix frame's `src` (see *Level strip*), so every path that reloads the whole frame — broadcasts (`assessment_sync_controller#mergeFocusParams`), `#reloadMatrixWithFocus`, `#navigateToCategoryTab` — reads the `levels[...]` entries back from the browser URL rather than from the frame's own `src`.
- Category chip clicks update the URL with `?category=` and dispatch a `matrix:focus-changed` event at category level so the activity feed narrows.

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

**Card-header click.** Clicking the card's header region (eyebrow + capability name + description) sets capability focus. Wired with `data-action="click->matrix#focusCapability"` scoped to the header (not the whole card) so clicks on the level strip and inside the expansion panel — which carry their own focus and interactive affordances — never accidentally land here. Re-clicking the same focused card's header toggles back to category focus, mirroring `focusCategory`'s behaviour. The header's text stays selectable, so a capability name can be copied: a click that ends with text selected in the header leaves focus alone. That covers a drag; a double-click still focuses the card on its first click, before anything is selected ([#492](https://github.com/mr-yum/growth-os/issues/492)).

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
"data-[focused=true]:shadow-lifted data-[focused=true]:ring-1 data-[focused=true]:ring-(--gos-border-default)"
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

There is no `×` close button. The previous design had one to drop back to "no level focused"; with auto-focus there's nothing meaningful to close *to*. Re-focusing means clicking a different level chip — handled by `matrix_controller#focusChip`, which sets the URL and swaps that one card.

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

A horizontal `flex` of `LevelChip`s, one per merged level ordinal. Each chip is colored by frequency × level position (same color rules the old matrix cells used). The assessee's current-level chip carries a badge — **"YOU" in self context, "CURRENT" in manager / alignment context** (the level belongs to the report, so "YOU" would mislead the manager) — and a darker outline when focused. Click dispatches `click->matrix#focusChip`, which sets `?capability=` + `?level_ordinal=` + `levels[<stable_id>]`, swaps **that one card** for the newly picked level, and smooth-scrolls the card under both sticky headers (unified + category section).

**A chip click never reloads the matrix ([#488](https://github.com/mr-yum/growth-os/issues/488)).** It used to: every click refetched the whole frame (~420 KB, every card, a ~100 ms main-thread block), and someone rating their current and next level does that once per capability. Now `#loadCard` fetches `GET /assessments/:id/capability_card?capability=&level_ordinal=` with `@rails/request.js`; the response is a Turbo Stream replacing `#capability-card-<stable_id>` (`CapabilityCard.dom_id_for`). Rules:

- **One render path.** The endpoint renders `AssessmentMatrix` with `only_capability:`, the matrix frame's own arguments (`AssessmentsController#matrix_view_args`) narrowed to one card, so the card can't drift from the one the frame renders. The URL, lens params included, rides on the matrix root as `data-matrix-card-url-value`; the framework explorer has none and keeps its own behaviour.
- **The response is the bare card**, not the list around it, so each swap replaces a card with a card.
- **The last click wins.** One fetch per card at a time, queued on the frame element (it outlives a controller instance across a broadcast reload); a click during a fetch queues its level, so the card always ends on the level last picked — including after a failure.
- **Never while the frame is loading.** A swap made before the frame's first load, or during a broadcast reload, would be overwritten when that load lands, so those clicks take the whole-frame path, which supersedes it.
- **The client places the focus ring.** The card arrives unfocused and the controller re-stamps the ring where focus is *now* — it may have moved while the fetch ran. Turbo renders a stream on a later frame than `get()` resolves, so the controller waits for the new node first.
- **Any failure falls back to the whole-frame reload** — a network drop, a session bounce (the fetch follows the redirect to an HTML page, which isn't a stream), a card no longer in scope (404). That path already has the recovery UI, and it replaces the history entry the click already pushed rather than adding a second.
- **The scroll starts at click time.** A card's top doesn't move when its contents change, so it doesn't wait for the response.

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

See [*Manager-rating delegation*](assessments/lifecycle.md) for the full delegate model.

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

## Frequency rating vocabulary

The four rating values share a single palette across every surface — inline pill, level chip, divergent-secondary dot — via `Views::Assessments::FrequencyPalette`. The palette uses a red → yellow → green → blue scale: four **maximally-distinct hues** so adjacent states never blur. This replaced the old red → orange → amber → green ramp, whose middle two (orange "Some" vs amber "Most") were near-indistinguishable on small chips — and unusable in a diagonal split (see *Level chip coloring*). Data values (enum, events, DB, test fixtures) **never** change.

| Enum | Sentence phrase | Compact label | Hue |
|------|----|----|----|
| `none` | Not yet | Not yet | red |
| `some` | Some of the time | Some | yellow |
| `occasional` | Most of the time | Most | green |
| `consistent` | Consistently | Consistently | blue |

The bottom of the scale reads **"Not yet"** on every surface — never "None" or "Never". "None" reads as a verdict ("you never do this") and discourages honest self-rating on a capability a person is still growing into; "Not yet" scores identically but frames the lowest rating as a starting point. Same split as the Feedback / Evidence relabel above: the domain value `none` (events, commands, read models, DB columns, the MCP `frequency` enum) is untouched. The pill, the divergence line and the activity feed all show those two words. Sentences that **compose** the phrase after a verb are the one exception: "rated not yet" means the opposite of what it says, so the chip's accessible name and the live-status announcement use the palette's `spoken` form — "rated not yet demonstrated" (`FrequencyPalette.spoken_for`). Same rule for the calibration distribution summary, which puts the count first ("3 Not yet", not "Not yet 3").

**A rating is against the expectation, never the example.** The `BehaviouralExpectation` is the one thing rated at a cell; role illustrations only help the rater read it. So a rating made while reading another role's examples on a shared cell is the same rating as the home one (see [*Role lens*](assessments/role-lens.md)).

Ordering is carried by **chip position** (E1…E8 left→right) and the **text label**, NOT by a single-axis colour gradient — so blue marking the top "Consistently" tier reads as a distinct band rather than "even greener than green". The phrase reads inside the inline pill ("…explains reasoning. **Most of the time**"); the compact label is for tight spaces. The hue backs both pill and level chip so the strip and the inline pill agree pixel-for-pixel.

**Blue is only safe as a rating colour because the keyboard-focus ring and selected-state are off blue.** Focus uses the neutral `focus-visible:ring-focus` role and selection the neutral fills ([#543](https://github.com/mr-yum/growth-os/issues/543)), never brand or blue; without that a blue "Consistently" chip would swallow its own focus ring, and blue already meant "selected" / `:performing`. The remaining blue use to watch when extending this: the hero's `:performing` performance-state accent — a separate surface (hero band, not chips), left as-is.

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
| Below person_level | Unrated | Mid blue `bg-rating-consistent-assumed`, `blue-300` in Default (assumed consistent — "Consistently" is blue, so a clearly-blue tint reads as consistent at a glance; kept a shade lighter than the solid `blue-500` of an explicit "Consistently" so the two stay distinguishable. An earlier near-invisible `blue-100/60` wash failed to register as a rating) |
| Below person_level | rated | Solid hue from the palette (red / yellow / green / blue) |
| At/above person_level | Unrated | Neutral gray |
| At/above person_level | rated | Solid hue from the palette — same fill regardless of level position |

**Rated chip fills are the exact `-500` (light) / `-400` (dark) shades the `FrequencyPalette` dots use everywhere else.** Same hue at the same saturation across pill / chip / divergence — the four ratings read as four distinct, equally-intense colours rather than four muddy near-identical tints. Text on rated chips uses `text-{hue}-950` in both modes for ~7–10:1 contrast against the saturated fill (WCAG AA on small text needs 4.5:1; lighter text tokens fail it on `yellow-500` / `green-500`).

### Misalignment → diagonal split (replaces the divergence dot)

When two perspectives the viewer can see **disagree**, the chip paints a **diagonal split** instead of a solid fill: a `/` seam from bottom-left to top-right, with the **viewer's own perspective in the top-left triangle** and the other party's bottom-right. **Position tracks the viewer, not a fixed self/manager assignment** — so a viewer always finds their own rating in the same corner, and the split reads identically across surfaces (NON-NEGOTIABLE: keep the two in sync). Concretely: the **manager** (or an active rating delegate) sees **their own rating top-left** in both the manager view and their alignment view; the **assessee** sees **their own (self) rating top-left** in their alignment view. So the manager view and the manager's alignment view are identical, and the assessee's alignment view is the mirror. The signal is threaded as `viewer_is_manager:` (true for the manager-side party) from the controller / page view down to `LevelChip` — `:manager` context is treated as manager-side by definition, and `:self` never splits, so the flag is only consulted in `:alignment`. Implemented as a base fill (the bottom-right colour) plus an absolute clip-path overlay (the top-left colour); the centered level code gets an opaque backing so it stays legible across the seam. A `data-split="true"` hook on the overlay supports testing.

> **Earlier design (superseded):** the corner used to track the context's *primary* perspective (manager view → manager top-left; alignment → self top-left, "reading order"). Because "primary" changes meaning between contexts, the two corners swapped between the manager view and the manager's alignment view — the ratings appeared to jump sides. Tying position to the viewer fixes it.

- **Why a split, not a coloured dot:** the *seam itself* is a shape signal — a split chip reads as "contested" regardless of the two colours, so it survives colour-blindness and the colours-too-close trap. It also shows *both values* in place.
- **Partial ratings split too:** when one perspective has rated and the other hasn't, the chip splits the rated colour against the missing slice — so "I rated, they haven't" doesn't masquerade as a mutual solid fill. The missing slice's colour depends on level: **at/above** the person's level it paints **grey** (genuinely unrated); **below** the person's level it paints the **assumed-consistent blue** (`blue-300`), the same default the solo chip and scoring use for a below-level cell, rather than grey — a grey slice there would wrongly read as "no rating" when the system in fact assumes consistency. The assumed default only fills a slice whose *counterpart was rated*; a below-level cell with neither perspective rated stays the lighter solo `blue-300` tint via the unrated branch. Crucially, an explicit `consistent` (solid `blue-500`) still **splits** against an assumed-consistent default (`blue-300`) — the two agree on the value but differ in explicit-vs-assumed, so both blue shades show in their perspective positions rather than collapsing to one fill. The chip renders solid only when both slices are *explicitly* rated and equal (or in a single-perspective context).
- **Per context:** `:self` never splits (only one perspective visible). `:manager` splits on self-vs-manager. `:alignment` splits on self-vs-manager **until a recorded aligned value resolves the cell to a solid** — so a contested cell visibly snaps solid as you record agreement (this also fixed the old "both rated but the chip is grey" bug, since the aligned value was empty pre-resolution). **Post-completion (`alignment_locked`), a residual split renders muted** (`opacity-60`, aria note "not reconciled during alignment"): a split's semantic is "contested — reconcile this", a call to action nobody can act on once everything is frozen, so it demotes to history. Only off-current-level cells can carry one — the completion gate (see [*Lifecycle*](assessments/lifecycle.md)) guarantees every current-level cell is solid.

### Evidence / comment → corner glyphs (replaces the slate/violet dots)

Content indicators live in the chip's **bottom-right corner as glyphs** — a **paperclip** (evidence) and a **speech bubble** (comment), on one muted backing pill (`text-gray-600`, `data-glyph="evidence"` / `data-glyph="comment"`). They stay on the chips (not the expansion) so "which levels have backing" is visible *before* drilling in. Glyphs not dots: a shape says what it is without a colour legend and can't be confused with the frequency-colour fill.

**The green rated-check ✓ was retired** — it read as "aligned" (it only ever meant "rated"), and the fill already encodes rated-vs-unrated. Full per-perspective values live in the expansion panel's `SecondaryRatingLine`s.

## Activity feed coverage (NON-NEGOTIABLE)

**Every action a user can take on the assessment screen MUST produce a
representation in the activity feed.** The feed is the assessment's audit
trail and shared narrative — if an action changes assessment state but leaves
no entry, the other party (and the actor on reload) silently loses the story.

> **Actionable entries.** When an assessment feed entry should let the viewer
> *act* on it inline (the way the framework feed lets a reviewer approve a
> pending suggestion), follow the **"actionable feed entry" pattern** documented
> in [framework-explorer.md §12](framework-explorer/suggestions.md): actionable iff
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

## Future Extension Points

- **Framework version migration UI for skipped seed values** — `RatingSeedSkipped` events are emitted but no read model / UI surface consumes them yet.
- **Growth Plans** — events defined (`GrowthGoalSet`, `FocusAreaAdded`, `CheckInRecorded`), no UI yet.
- **Notifications and Snapshots** — both are listed in architecture docs; neither has any infrastructure today.

## Keeping This Guide Current

Update the file that holds the section — see *Where everything lives* above — whenever the assessment architecture, interaction patterns, components or Stimulus controllers changes:

- **New design decisions** — add with rationale to the file for that concern, and to the map if it starts a new one
- **Bug fixes revealing non-obvious behaviour** — add to the lessons file, at the next number, and add its title to the index above
- **New or modified components** — update the file reference
- **New Stimulus controllers or changed responsibilities** — update the Stimulus controllers file

Never renumber a section or a lesson: code comments and other guides cite them. Keep this entry point small enough to load on every visit; a concern that grows large moves to its own file. `test/integration/agent_guidance_test.rb` fails when what one directory loads passes 100k characters (this core, plus the guides of every directory above it), and when any guide passes Claude Code's 150k per-file limit.

If a lesson or decision is superseded, update or remove the old entry rather than appending a contradiction.
