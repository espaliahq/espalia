# Assessment UX — Design & Architecture

This document captures the design decisions, interaction patterns, and hard-won lessons from building the assessment views (self-assessment, manager assessment, and alignment). Consult this before modifying assessment UX or building features that extend it.

> **See also:** [framework-explorer.md](framework-explorer.md) for the underlying matrix pattern that assessments extend.

## Overview

The assessment UX uses a **tabbed, single-category-at-a-time** view. Rather than showing all categories in one matrix, a tab bar above the table lets users focus on one category at a time. Each tab shows the category name, a rated/total progress count, and a pass/fail status dot.

The matrix pattern uses a **parallel view hierarchy** in `app/views/assessments/`. Rather than adding a mode parameter to the explorer's `MatrixCell`, a separate set of assessment-specific components was built. This keeps the read-only explorer simple and gives assessment cells the interactive controls they need (frequency selectors, secondary rating bars, background coloring).

### URL-Driven State

The active category and expanded capability are encoded in query params for shareability:

```text
Browser:      /assessments/:id?category=<category_id>&capability=<stable_id>
Matrix frame: /assessments/:id/matrix?category=<category_id>&capability=<stable_id>
Scoring frame:/assessments/:id/scoring?category=<category_id>
```

- `category` absent → defaults to first category (ordinal 1)
- `capability` absent → no row pre-expanded
- Tab clicks update both the Turbo Frame src and the browser URL via `history.pushState()`

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
- **Self** (`context: :self`) → `ShowView` — person rates themselves
- **Manager** (`context: :manager`) → `ManagerShowView` — manager rates their direct report

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
  when :self      # shows Mgr + Agreed as read-only bars
  when :manager   # shows Self + Agreed as read-only bars
  when :alignment # shows Self + Mgr as read-only bars
  end
end
```

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

## Stimulus Controller Responsibilities

### assessment_sync_controller.js
- **ActionCable sync** — observes a signal element via `MutationObserver` for Turbo Stream replacements
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
- **URL sync** (assessment only, gated behind `urlSyncValue`) — syncs `?category=` and `?capability=` to browser URL via `pushState` after Turbo Frame loads and row toggles
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

**Header pills.**
- Manager view, status `started`: a "Start alignment" `<form>` with `data-turbo-confirm` warning that self + manager ratings will lock. Hidden on mobile (`hidden md:inline-block`) — the action is significant enough to warrant desktop confirmation; mobile pages still allow alignment after a manager opens it elsewhere.
- Manager view, status `aligning` / `aligned`: a "Continue alignment" link to `?mode=alignment`.
- Manager view in `:alignment` context with status `aligning`: an extra green "Mark alignment complete" button (also `data-turbo-confirm`).
- Self view, status `aligning`: an "Aligning with manager" warning badge in the second badge row (no edit pill).
- Self view, status `aligned`: an "Aligned" success badge (no edit pill).

**`AlignmentStartsController` / `AlignmentCompletionsController`** dispatch the lifecycle commands and redirect back to `assessment_path(@assignment, mode: "alignment")` (start) or `assessment_path(@assignment)` (complete). Both rescue `RuntimeError` from the aggregate to surface a generic flash alert (the underlying message is logged via `Rails.logger.error` only).

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
