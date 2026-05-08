# Assessment UX — Design & Architecture

This document captures the design decisions, interaction patterns, and hard-won lessons from building the assessment views (self-assessment, manager assessment, and alignment). Consult this before modifying assessment UX or building features that extend it.

> **See also:** [framework-explorer.md](framework-explorer.md) for the underlying matrix pattern that assessments extend.

## Overview

The assessment UX uses a **tabbed, single-category-at-a-time** view. Rather than showing all categories in one matrix, a tab bar above the table lets users focus on one category at a time. Each tab shows the category name, a rated/total progress count, and a pass/fail status dot.

The matrix pattern uses a **parallel view hierarchy** in `app/views/assessments/`. Rather than adding a mode parameter to the explorer's `MatrixCell`, a separate set of assessment-specific components was built. This keeps the read-only explorer simple and gives assessment cells the interactive controls they need (frequency selectors, secondary rating bars, background coloring).

### URL-Driven State

The active category, expanded capability, and focused cell-level are encoded in query params for shareability:

```text
Browser:      /assessments/:id?category=<category_id>&capability=<stable_id>&level_ordinal=<n>
Matrix frame: /assessments/:id/matrix?category=<category_id>&capability=<stable_id>&level_ordinal=<n>
Scoring frame:/assessments/:id/scoring?category=<category_id>
```

- `category` absent → defaults to first category (ordinal 1)
- `capability` absent → no row pre-expanded
- `capability` is the capability's **stable_id** (cross-version UUID), not the per-version `capability_id`. The server compares `params[:capability] == stable_id` when deciding which row to pre-expand; the browser URL must use stable_id so reloads (manual F5 + post-broadcast frame swaps) restore focus.
- `level_ordinal` only honoured when `capability` is also present (cell focus lives inside an expanded row)
- Tab clicks, row-toggle clicks, and cell-focus clicks update the browser URL via `history.pushState()`. `matrix_controller#syncFocusToUrl` writes `capability` and `level_ordinal` together in **one** push, no-ops when both already match, so Back/Forward maps 1:1 to visible focus changes.
- The matrix Turbo Frame's `src` is NOT mutated on focus changes (would trigger a fetch). Instead, `assessment_sync_controller#mergeFocusParams` merges current browser URL params (`capability` + `level_ordinal`) into the frame's src at reload time, so focus survives broadcast-driven frame reloads.

## Cell focus

When a row is expanded, clicking an expanded-row `<td>` focuses that capability × level intersection. The focused level's matrix column widens (32rem) and sibling level columns keep their default 280px width so the FrequencySelector still fits on a single row — the focused cell — expectation, illustrations, evidence list, and "+ Add evidence" affordance — gets breathing room. Clicking the close button (`×`, top-right of the focused cell) returns to capability-level focus; the row stays expanded.

**Implementation:**

- `Views::Assessments::AssessmentMatrix` renders a `<colgroup>` with one `<col data-matrix-target="col">` per merged level (plus a 220px-fixed capability col). Default level cols use `width: 280px` — wide enough that the FrequencySelector's four buttons (including the long "Consistently" label) fit on a single row regardless of how many levels the framework has. The `<table>` keeps the browser's default `table-layout: auto` so cell `min-w-[180px]` still applies; the parent `overflow-x-auto` scrolls horizontally when the table grows past the container.
- `matrix_controller#applyColumnFocus(levelOrdinal, capabilityId)` switches the table to `table-layout: fixed` via inline style, sets the focused col's width to `512px` (32rem) and siblings to `280px` (matching their default so the FrequencySelector still fits on one row), and pins the table's total width to the sum of col widths so browsers don't proportionally scale them when the sum exceeds the container. The "additive" widening (focused gets wider, siblings keep their default) means siblings remain fully usable while the user has a focused cell. Clearing the focus reverts every inline style and Tailwind reasserts.
- After applying col widths, `#applyColumnFocus` scrolls the focused expanded `<tr>` (or the compact cell when no expanded row is present) into view vertically with `block: "nearest"`, then calls `#scrollHorizontallyPastStickyCap` to make sure the focused cell's left edge sits at or past the sticky capability column's right edge. A naive `inline: "center"` would park focus on the first level directly under the sticky cap, hiding the focused content. The scroll is deferred via `requestAnimationFrame` so the browser computes positions against the post-resize layout.
- `unfocusCell` is a public Stimulus action wired on the close button: it returns to capability-level focus, leaving the row expanded.
- The close button (`[data-focused-cell-close]`) is rendered inside the **compact cell**, top-right (absolute position). The compact cell is the user's anchor — placing the X next to where they clicked keeps the affordance discoverable without burying it in the illustration list below.
- Both **compact** and **expanded** `<td>`s carry `data-action="click->matrix#focusCell"` plus `data-capability-id`, `data-capability-stable-id`, `data-level-ordinal`, and `data-expectation-id`. Compact cells additionally carry `data-focus-on-button-click="true"` so a tap on a rating button BOTH triggers the rating submit AND focuses the cell — without that flag the focusCell guard would skip clicks that landed on interactive children. `focusCell` also calls `#expandRow(capabilityId)` so a click on a compact cell's expectation text or rating button expands the row in the same gesture.
- **Keyboard a11y**: the compact cell carries `tabindex="0"`, `role="button"`, a per-cell `aria-label="Focus cell: <capability> · <level>"` (composed from `capability_name` + level title), and Stimulus actions `keydown.enter.self->matrix#focusCell` + `keydown.space.self->matrix#focusCell:prevent`. The `.self` modifier scopes activation to the cell itself so nested rating buttons keep their native keyboard activation.
- **URL is the source of truth for focus restoration.** On controller connect, `dispatchInitialFocus` first calls `#focusFromUrl` — if the browser URL has `capability` + `level_ordinal` AND a matching `<td>` exists in the rendered DOM, it restores cell focus and exits. Only if URL params are absent or stale (the `<td>` doesn't exist — e.g. a dropped level after a framework version change) does it fall back to the server-rendered `data-focused-level-ordinal` on the visible expanded row, then to capability/category fallbacks. This makes focus survive page reloads, deep links, and frame replacements even when the focused capability has no expanded content server-side.

**Don't hide the FrequencySelector when shrinking sibling columns.** It's the primary rating affordance — making it disappear is a regression. The siblings keep their default 280px width specifically so the buttons remain on one row. Hang density tweaks off the `data-focus-compact="true"` attribute the controller stamps on sibling cells via `group-data-[focus-compact=true]/assess-cell:` Tailwind variants — never replace the selector with a read-only bar based on focus state alone.

## Context-Driven Rendering

A single `context` symbol (`:self`, `:manager`, or `:alignment`) threads through the entire request — from controller detection to form action URLs.

The controller detects context by comparing the assignment's person to the current user:

```ruby
# assessments_controller.rb
def assessment_context
  manager_viewing? ? :manager : :self
end

def manager_viewing?
  @assignment.person_id != current_person.id
end
```

This routes to different views:
- **Self** (`context: :self`) → `ShowView` — person rates themselves. Manager and aligned ratings are hidden — see *Self-assessment privacy* below.
- **Manager** (`context: :manager`) → `ManagerShowView` — manager rates their direct report
- **Alignment** (`context: :alignment`) → automatic once the manager has formally started alignment (cycle status `aligning` or `aligned`). Both parties see all three rating perspectives. Gated by `AssessmentPolicy#view_alignment?`. There is no opt-in URL param and no in-page toggle — being in an alignment-phase assessment **is** alignment mode.

### Self-assessment privacy

The assessee must not see the manager's rating until alignment formally begins. This is enforced at two layers:

1. **Data layer** — `Assessments::MatrixDataBuilder` accepts a `context:` kwarg. When `context == :self`, manager and aligned data are scrubbed from the result — `manager_frequency` / `aligned_frequency` per cell, plus `manager_scoring` / `aligned_scoring` at the top level. The primary scoring perspective is also forced to `:self_only` so the effective fallback chain (aligned → manager → self) cannot leak manager-derived numbers into the displayed totals.
2. **Policy layer** — `AssessmentPolicy#view_alignment?` requires the participant's cycle status to be `aligning` or `aligned`. Until the manager has formally started alignment, the assessee renders in `:self` context regardless of any URL params. The controller treats stale `?mode=alignment` query strings as no-ops.

## Component Hierarchy

```
PageLayout
└── div[data-controller="assessment-sync panel"]
    ├── assessment_header (back link, framework name, progress badge)
    └── assessment_layout
        ├── main
        │   └── turbo-frame#assessment-matrix
        │       └── div[data-controller="matrix" data-matrix-url-sync-value="true"]
        │           ├── CategoryTabs (horizontal scrollable tab bar)
        │           │   └── tab links → /assessments/:id/matrix?category=<id>
        │           └── table (single-category matrix)
        │               ├── MatrixHeader (level columns, person_level highlighted)
        │               └── AssessmentCategoryGroup (active category only, no header)
        │                   └── AssessmentRow (per capability)
        │                       ├── compact row (CapabilityNameCell + AssessmentCells)
        │                       │   └── siblings dimmed when any row expanded
        │                       └── expanded row (illustrations, URL-driven pre-expansion)
        │                           └── AssessmentCell (per level ordinal)
        │                               ├── expectation text
        │                               ├── secondary FrequencyBars (read-only)
        │                               ├── primary FrequencySelector (interactive, category_id hidden field)
        │                               └── illustration indicator
        └── aside (scoring panel sidebar)
            └── turbo-frame#assessment-scoring
                └── ScoringPanel (multi-perspective, clickable category links)
```

## Data Flow

```
AssessmentsController (detects self/manager context)
  → Assessments::MatrixDataBuilder (loads ratings, builds 4 scoring perspectives)
    → ShowView / ManagerShowView (renders Phlex components with context)
      → FrequencySelector posts to /ratings or /manager_ratings
        → RatingsController / ManagerRatingsController
          → PersonDevelopment::CommandHandler (rate_self / rate_as_manager)
            → Event published → Projection updates AssessmentLevelRating
              → Turbo Stream broadcasts → assessment_sync_controller reloads frames
```

Key difference from the explorer: the `Assessments::MatrixDataBuilder` is a **single-role** builder (the person's assigned role) rather than multi-role. It enriches each cell with three frequency fields and computes four parallel scoring perspectives.

## How Context Flows Through Components

### AssessmentCell — the core of context-aware rendering

```ruby
def primary_frequency
  case @context
  when :self      then @cell_data[:current_frequency]    # self_rated_frequency
  when :manager   then @cell_data[:manager_frequency]    # manager_rated_frequency
  when :alignment then @cell_data[:aligned_frequency]    # aligned_frequency
  end
end

def secondary_rating_entries
  case @context
  when :self      # shows nothing — manager and aligned ratings are private
                  # to the manager until alignment formally begins
  when :manager   # shows Self + Agreed as read-only bars
  when :alignment # shows Self + Mgr as read-only bars
  end
end
```

In `:self` context, manager and aligned data are scrubbed from `cell_data` (and `manager_scoring` / `aligned_scoring` set to `nil`) by `Assessments::MatrixDataBuilder` itself — defense-in-depth, so the data never reaches the assessee's HTML, not just hidden in CSS.

### FrequencySelector — context determines the POST endpoint

```ruby
def form_action
  case @context
  when :manager then assessment_manager_ratings_path(@assessment_id)
  else               assessment_ratings_path(@assessment_id)
  end
end
```

### ScoringPanel — context determines which perspective is primary

```ruby
def primary_scoring
  case @context
  when :self      then @self_scoring || @scoring       # falls back to effective
  when :manager   then @manager_scoring || @scoring
  when :alignment then @aligned_scoring || @scoring
  end
end
```

Secondary perspectives appear as compact bars. An amber dot indicates divergence (≥5% difference from primary).

### AssessmentCategoryGroup — category-level scoring follows the same pattern

```ruby
# Category pass/fail, contribution pool, blocked status, and per-capability
# contributions all come from the primary scoring perspective.
def primary_scoring
  case @context
  when :self      then @self_scoring || @scoring
  when :manager   then @manager_scoring || @scoring
  when :alignment then @aligned_scoring || @scoring
  end
end
```

An amber divergence dot appears on category headers when secondary perspectives disagree on pass/fail. Capability contribution labels and blocked status also follow the primary perspective.

## Frequency Rating Vocabulary

The four rating values have distinct display labels and underlying enum values. UI buttons use the short form; tooltips and aria-labels use the long form. Data values (enum, events, DB, test fixtures) **never** change.

| Enum value | Short label (button/bar) | Long label (tooltip/aria) |
|------------|--------------------------|---------------------------|
| `none` | None | None |
| `some` | Some | Some times |
| `occasional` | Most | Most times |
| `consistent` | Consistently | Consistently |

The `FrequencyBar` component abbreviates further when space-constrained (`Con.` for `consistent`), but still carries the long label as a `title` attribute.

## Cell Background Coloring

Cell backgrounds encode frequency + level position at a glance:

| Level Position | Frequency | Background |
|---------------|-----------|------------|
| Below person_level | Unrated | Muted green (assumed consistent) |
| Below person_level | Consistently (`consistent`) | Solid green |
| Below person_level | Most times (`occasional`) | Amber |
| Below person_level | Some times / None | Red |
| At/above person_level | Unrated | Neutral gray |
| At/above person_level | Consistently (`consistent`) | Solid green |
| At/above person_level | Some times / Most times | Blue (stretch attempt) |

## Multi-Perspective Scoring

`Assessments::MatrixDataBuilder` builds four parallel scoring outputs:

| Key | Perspective | Frequency Used |
|-----|------------|----------------|
| `scoring` | `:effective` (default) | Fallback chain: aligned → manager → self |
| `self_scoring` | `:self_only` | Only `self_rated_frequency` |
| `manager_scoring` | `:manager_only` | Only `manager_rated_frequency` |
| `aligned_scoring` | `:aligned_only` | Only `aligned_frequency` |

Each uses `PersonDevelopment::Scoring` with a different `perspective:` parameter. A perspective returns `nil` (not empty) when no ratings exist for it — `ScoringPanel` detects this via `using_fallback?` and shows a "No ratings yet" badge.

The `ScoringPanel` displays:
- **Performance ratio** as primary percentage + progress bar
- **Status tier**: Below expectations / Meeting expectations / Mastering
- **Category results** with pass/fail per category
- **Promotion readiness** at next level
- **Divergence annotations** when secondary perspectives disagree on tier, category pass/fail, or promotion eligibility

## Real-Time Sync

Rating changes by another viewer (e.g. a manager rating while the person has their own assessment open) are broadcast via ActionCable. The `assessment_sync_controller` observes a signal element for Turbo Stream replacements and triggers a full frame reload, preserving the user's toggle state (expanded rows, collapsed categories).

```
ActionCable broadcast → Turbo Stream replaces signal element
  → MutationObserver fires → save toggle state
    → reload matrix + scoring frames
      → turbo:frame-load → restore toggle state + update score badge
```

**The rater's own broadcast echo is suppressed.** The `CurrentAssessment` projection broadcasts on every rating event, and ActionCable delivers that broadcast back to the rating user too — without intervention, this would re-fetch the entire matrix frame for the user who just acted (flicker, scroll reset). The direct Turbo Stream response from the rating endpoint already updates the affected cells locally, so the broadcast for our own action is redundant.

`assessment_sync_controller#listenForOwnSubmits` arms a 5-second `_suppressReloadUntil` window on the EARLIEST signal of a user-initiated form submit — `pointerdown`, `mousedown`, or `click` (capture phase) on a real submit control (`button[type='submit']`, default-type `<button>` inside a form, `input[type='submit']`) belonging to a form contained by this controller, plus `turbo:submit-start` as a backstop for programmatic submits. The arming is narrowed to actual submit controls (not all interactive clicks) so we don't hide legitimate broadcasts from other users after non-submit interactions like opening a dropdown.

When the broadcast arrives within the window, the MutationObserver's reload callback returns early. Outside the window, the reload proceeds as normal — preserving the multi-viewer sync semantics.

## Stimulus Controller Responsibilities

### assessment_sync_controller.js
- **ActionCable sync** — observes a signal element via `MutationObserver` for Turbo Stream replacements
- **Self-broadcast suppress** — arms a 5s `_suppressReloadUntil` window on `pointerdown`/`mousedown`/`click` capture against any real submit control (`button[type='submit']`, default-type `<button>` in a form, `input[type='submit']`) inside this controller, plus `turbo:submit-start` as backstop. The MutationObserver bails when within the window so the rater's own broadcast doesn't trigger a redundant frame reload (flicker + scroll reset)
- **Focus-param merge on reload** — `#mergeFocusParams` reads `capability` + `level_ordinal` from the BROWSER URL (kept current by matrix_controller's URL sync) and stamps them onto the matrix frame's `src` before reload, so focus state survives broadcast-driven frame reloads
- **Toggle state preservation** — saves expanded rows and collapsed categories before frame reload, restores after
- **Scoring badge update** — reads `data-performance-pct` from the scoring panel and updates the header badge color/text
- **Dual frame reload** — reloads both the matrix frame and the scoring panel frame on rating changes
- **Category sync** — after every matrix frame load, copies the `?category=` param from the matrix frame's `src` to the scoring frame's `src` and reloads it, keeping the scoring panel's active category highlight in sync with the tab bar

### frequency_selector_controller.js
- **Optimistic UI** — highlights the clicked frequency button immediately before the Turbo Stream response arrives
- Lightweight controller; form action routing is handled server-side by `FrequencySelector` view component

### matrix_controller.js (shared with explorer)
- **Category collapse** (sibling row walking) — not used in assessment view (single category)
- **Row expansion** (toggle hidden expanded row by capability ID)
- **Cell focus** (`focusCell` action on compact AND expanded `<td>`, plus `keydown.enter.self`/`keydown.space.self` for keyboard activation) — dispatches `matrix:focus-changed` with `level: "cell"` and resizes columns via `#applyColumnFocus`. Compact-cell click also calls `#expandRow` so the gesture both opens the row and focuses the cell. **Assessment-only behaviour**: explorer's expanded cells emit the same focus event but render no `<colgroup>`, so the column-resize is a no-op there.
- **Cell unfocus** (`unfocusCell` action on the per-cell `×` close button) — returns to capability-level focus, leaving the row expanded
- **URL sync** (assessment only, gated behind `urlSyncValue`) — `#syncFocusToUrl` writes `?capability=<stable_id>` + `?level_ordinal=<n>` together in one `pushState` (or clears them) on every focus transition. `#syncFrameUrlToBrowser` only mirrors `?category=` from the frame's `src` to the browser URL — `capability`/`level_ordinal` are owned by JS focus state, never overwritten from the frame
- **URL-first focus restoration** — `#dispatchInitialFocus` calls `#focusFromUrl` first; if the browser URL has `capability` + `level_ordinal` AND a matching `<td>` exists, restore cell focus from the URL. Stale URLs (no matching `<td>`) bail to the capability/category fallback.
- **Sibling dimming** — dims non-expanded rows (`opacity-40`) when a row is expanded for visual focus
- See [framework-explorer.md](framework-explorer.md) for full responsibilities

## Key Design Decisions

### Tabbed categories with server-side switching

Instead of showing all categories at once, the assessment renders one category at a time via a tab bar. Each tab click fetches a Turbo Frame with `?category=<id>`. This was chosen over client-side show/hide because:

1. **Payload reduction** — only one category's DOM is rendered, not all
2. **Data freshness** — each tab switch gets the latest rating state from the server
3. **Consistency** — matches the framework explorer pattern where role selection drives Turbo Frame fetches
4. **No client-side tab state** — tabs live inside the Turbo Frame and re-render on every load, so active state is always correct

The category header row is omitted when rendering a single category (the tab bar serves as the category identifier).

### URL-driven focus state

The active category and expanded capability are query params, enabling:
- Bookmarking a specific category + capability view
- Sharing deep links to a particular assessment focus
- Browser back/forward navigation between category views
- Server-side pre-expansion of rows from shared URLs

### Scoring panel as navigation

Category names in the scoring panel sidebar are clickable links that switch the active tab. When the matrix frame loads with a new category, the `assessment_sync_controller` syncs the scoring frame to update the active category highlight.

## Hard-Won Lessons

### 1. Separate view hierarchies over multi-mode components

The original plan was to add a `mode` parameter to `MatrixCell` for explorer/assessment/review. In practice, a parallel `app/views/assessments/` hierarchy with its own cell/row/matrix components was cleaner — assessment cells need frequency selectors, secondary bars, and background coloring logic that doesn't belong in the read-only explorer.

### 2. Context threading must be end-to-end

The `:self`/`:manager` context flows from controller detection (`manager_viewing?`) through the builder, into every view component, and into form action URLs. Missing the context at any layer — especially `FrequencySelector#form_action` — routes ratings to the wrong endpoint silently.

### 3. Toggle state preservation across Turbo Frame reloads

When a rating changes, `assessment_sync_controller` reloads the matrix frame. Without saving/restoring expanded rows and collapsed categories, the user loses their scroll position and state. The controller uses a save/restore cycle around each reload via DOM queries before the fetch and re-application after `turbo:frame-load`.

### 4. Category data contains model objects, not plain hashes

`matrix_data[:categories]` contains `{ category: CapabilityCategory, ... }` where `category` is an ActiveRecord model, not a hash. Use `.dig(:category)&.category_id` (two-step), not `.dig(:category, :category_id)` — the latter requires `#dig` on the model which doesn't exist.

### 5. Perspective scoring returns nil, not empty

`build_perspective_scoring` returns `nil` (not an empty hash) when no ratings exist for a perspective. `ScoringPanel` checks this via `using_fallback?` and falls back to effective scoring, showing a "No ratings yet" badge. Returning an empty hash would display misleading zero scores.

### 6. `table-fixed` ignores `min-w-*` on cells

The cell-focus column resize requires `<colgroup>` + explicit `<col>` widths under `table-fixed`. Once `table-fixed` is on, every `min-w-[180px]` on a `<th>` or `<td>` becomes inert — column widths come solely from the `<col>` elements. The capability column needs an explicit `width: 220px` style to preserve the prior layout; level cols are unstyled by default so they auto-divide remaining width evenly. If you rely on cell-content-driven sizing anywhere in the matrix, it will silently stop working.

### 7. `<col>` width transitions don't animate in WebKit

When `matrix_controller#applyColumnFocus` sets `style.width` on a `<col>`, browsers do not animate the transition (Chromium/WebKit treat `<col>` as a layout primitive, not a transition source). Don't add `transition-[width]` and try to fight this — instant resize is the correct UX for cell focus and matches user expectation. Tested behaviour, accepted trade-off.

## Lifecycle

Each enrolled `AssessmentCycleParticipant` walks a lifecycle that the views render explicitly:

```text
enrolled → started → aligning → aligned → withdrawn
```

| Status | Trigger | What's editable |
|---|---|---|
| `enrolled` | `PersonEnrolled` lands; participant created | Self + manager ratings |
| `started` | First `SelfRated` / `ManagerRated` event with `source: "human"` | Self + manager ratings |
| `aligning` | Manager fires `AlignmentStarted` (manager-only command) | Aligned values only — self + manager are FROZEN |
| `aligned` | Manager fires `FullAlignmentCompleted` (manager-only) | Nothing — all ratings, including aligned values, are frozen |
| `withdrawn` | Person unenrolled or cycle closed | Nothing |

**Threading the status to the views.** `MatrixDataBuilder` reads `participant_status` (controller derives via `assignment.current_open_cycle_participant&.status`) and produces two boolean flags on the matrix data hash:
- `individual_ratings_frozen` — true for `aligning` / `aligned`. Threaded into `AssessmentRow` and `AssessmentCell` as `frozen:`. When the cell context is `:self` or `:manager`, the primary `FrequencySelector` is replaced with a read-only `FrequencyBar`.
- `alignment_locked` — true only for `aligned`. Threaded in as `alignment_locked:`. When the cell context is `:alignment`, the alignment selector also becomes a read-only bar.

Both flags also flow through the rating controllers' Turbo Stream `respond_with_turbo_stream` paths so post-event re-renders pick the correct read-only / interactive shape.

**Header layout.** Both views render a single-row header (`flex flex-wrap items-baseline gap-x-3 gap-y-1`) consisting of an H1, a monospace shortcode chip, a status pill, and a right-aligned action cluster:

- **Self view** — H1 is the level title (e.g. "Senior Engineering Manager"); shortcode chip is `"#{role.code}#{level.ordinal}"` (e.g. `EM5`); status pill is one of `In Progress` / `Aligning` / `Aligned` (rendered only when `current_open_cycle` exists). The framework name and version badge are intentionally omitted — they live on the back link / index card. The role-name pill is also omitted (the level title already carries the role context, and the shortcode disambiguates).
- **Manager view** — H1 is `assessee.name`; a secondary subtitle span renders the level title; same shortcode chip and status pill follow. The "Manager Review" badge is omitted — the assessee's name as H1 plus the back link to `Assessments` is sufficient context.

**Status pill.** Single helper `render_status_pill` returns one badge based on `participant_status` (`aligning` → warning, `aligned` → success) or falls back to "In Progress" warning when an open cycle exists. Self view never duplicates this with an extra "Aligning with manager" badge.

**Action cluster (right side).**
- Manager view, status `started`: "Start alignment" `<form>` with `data-turbo-confirm` warning that self + manager ratings will lock. Hidden on mobile (`hidden md:inline-block`).
- Manager view, status `aligning`: "Mark alignment complete" green button with `data-turbo-confirm` warning that aligned values will be frozen.
- Status `aligning` or `aligned`: no toggle — the assessment renders in alignment mode automatically. Both parties see all three rating perspectives without any UI affordance to enter or exit alignment.

**`AlignmentStartsController` / `AlignmentCompletionsController`** dispatch the lifecycle commands and redirect back to `assessment_path(@assignment)`. Both rescue `RuntimeError` from the aggregate to surface a generic flash alert (the underlying message is logged via `Rails.logger.error` only).

**Auto-alignment on start.** Inside the same RES transaction as `AlignmentStarted`, `PersonDevelopment::CommandHandler#start_alignment` emits an `AssessmentAligned` event for every (capability × level) cell where both `self_rated_frequency` and `manager_rated_frequency` are explicitly recorded **and equal**. The conversation in alignment mode then focuses on disagreements and unrated cells. Default-fallback agreements (where one or both perspectives never recorded an explicit value) are NOT auto-aligned — an aligned event represents a positive act of agreement between two recorded positions, not an absence of dispute. Auto-aligned events carry the comment "Auto-aligned: self and manager already agreed" for forensic distinction.

**Cross-cycle seeding.** When a person enrols in a new cycle for a framework where they previously completed alignment, both their self and manager ratings are pre-populated from the prior cycle's `aligned_frequency`. The seeded events carry `source: "seeded"` (vs the default `"human"`) and `seeded_from_cycle_id`. The participant stays in `enrolled` until the user makes their first real edit — seeded events alone do not trigger `started`, and the projection's `apply_source` flips the row's source back to `"human"` on any user revise. See `PR 4` of the assessment-lifecycle plan for full details.

## Future Extension Points

### Framework version migration UI for skipped seed values
`RatingSeedSkipped` events are already emitted on the person-development stream when a prior aligned capability's `stable_id` no longer exists in the new cycle's framework — but no read model or UI surface consumes them yet. Once framework-version migration mappings ship, the migration UI should replay these events and surface a "use this rating against `<migrated equivalent>`" affordance.

### Evidence Collection
Events are defined (`EvidenceRecorded`, `EvidenceRelinked`, `EvidenceWithdrawn`) but no UI exists. Cell expansion would show an evidence attachment UI, letting users link evidence to a specific capability × level intersection.

### Growth Plans
Events are defined (`GrowthGoalSet`, `FocusAreaAdded`, `CheckInRecorded`) but no UI or read model projection exists yet.

### Notifications and Snapshots
Both are listed in the architecture docs as cross-cutting concerns. Neither has any infrastructure today; PR 3 of the lifecycle plan specifically deferred snapshot subscription on `FullAlignmentCompleted` until a `PersonDevelopment::Snapshotting` async handler exists.

## File Reference

| File | Purpose |
|------|---------|
| **Views** | |
| `app/views/assessments/category_tabs.rb` | Horizontal tab bar for category switching (inside Turbo Frame) |
| `app/views/assessments/show_view.rb` | Self-assessment two-pane layout (matrix + scoring sidebar) |
| `app/views/assessments/manager_show_view.rb` | Manager assessment layout |
| `app/views/assessments/index_view.rb` | Assessment list (own + direct reports) |
| `app/views/assessments/assessment_matrix_frame_view.rb` | Turbo Frame wrapper for assessment matrix |
| `app/views/assessments/assessment_matrix.rb` | Assessment matrix table container |
| `app/views/assessments/assessment_category_group.rb` | Category group with contribution labels |
| `app/views/assessments/assessment_row.rb` | Context-aware capability row |
| `app/views/assessments/assessment_cell.rb` | Context-aware cell (self/manager/alignment) |
| `app/views/assessments/matrix_header.rb` | Level columns with person_level highlight |
| `app/views/assessments/frequency_selector.rb` | Four-button rating control (None/Some/Most/Consistently) |
| `app/views/assessments/frequency_bar.rb` | Read-only secondary rating bar with divergence dot |
| `app/views/assessments/scoring_panel.rb` | Multi-perspective scoring sidebar |
| `app/views/assessments/scoring_panel_frame_view.rb` | Scoring panel Turbo Frame |
| `app/views/assessments/capability_name_cell.rb` | Capability name with contribution indicator |
| `app/views/assessments/category_contribution_label.rb` | Category pass/fail badge |
| `app/views/assessments/category_status.rb` | Category status indicator |
| `app/views/assessments/contribution_label.rb` | Capability contribution indicator |
| `app/views/assessments/rating_error.rb` | Rating error flash |
| **Controllers** | |
| `app/controllers/assessments_controller.rb` | show/index/matrix/scoring with self/manager/alignment context routing |
| `app/controllers/assessments/ratings_controller.rb` | Self-rating POST (rate_self, revise, clear) |
| `app/controllers/assessments/manager_ratings_controller.rb` | Manager-rating POST (rate_as_manager, revise, clear) |
| `app/controllers/assessments/alignment_ratings_controller.rb` | Per-cell alignment POST (align_assessment) |
| `app/controllers/assessments/alignment_starts_controller.rb` | Manager-only POST that fires `AlignmentStarted` and locks individual ratings |
| `app/controllers/assessments/alignment_completions_controller.rb` | Manager-only POST that fires `FullAlignmentCompleted` and locks all ratings |
| **Data** | |
| `app/models/assessments/matrix_data_builder.rb` | Single-role builder with ratings + 4-perspective scoring |
| `app/read_models/assessment_level_rating.rb` | Three-frequency read model (self/manager/aligned) |
| `app/read_models/person_framework_assignment.rb` | Person-framework-role-level assignment |
| **JavaScript** | |
| `app/javascript/controllers/assessment_sync_controller.js` | ActionCable sync, toggle state preservation |
| `app/javascript/controllers/frequency_selector_controller.js` | Optimistic frequency button UI |
| **Tests** | |
| `test/system/assessments_system_test.rb` | Self-assessment system tests |
| `test/system/manager_assessments_system_test.rb` | Manager assessment system tests |

## Keeping This Document Current

This document must be updated whenever changes are made to the assessment architecture, interaction patterns, component hierarchy, or Stimulus controllers. Specifically:

- **New design decisions** — add with rationale (e.g. new context type, new scoring perspective)
- **Bug fixes revealing non-obvious behaviour** — add to Hard-Won Lessons
- **New or modified components** — update the Component Hierarchy and File Reference
- **New Stimulus controllers or changed responsibilities** — update the Stimulus Controller Responsibilities section
- **New future extension points** — add to Future Extension Points; remove entries that have been implemented

If a lesson or decision is superseded, update or remove the old entry rather than appending a contradiction.
