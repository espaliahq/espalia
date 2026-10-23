# Framework Explorer — UX Design & Architecture

This document captures the design decisions, interaction patterns, and hard-won lessons from building the Framework Explorer. Consult this before modifying the explorer or building features that extend it.

> **See also:** [assessments.md](assessments.md) for the assessment extension of the matrix pattern.

> **Terminology — "example" on the surface, "illustration" in the domain.** A
> `RoleIllustration` is shown to users as an **example** everywhere: matrix
> cell counts ("3 examples"), the expanded row, the "+ Add example" affordance,
> the "Example actions" kebab, feed entries ("Added an example"), suggestion
> badges, modal copy, toasts, error messages, and MCP tool *descriptions*. The
> **domain vocabulary is unchanged**: events (`RoleIllustrationAdded`…),
> commands, read models (`FrameworkState::RoleIllustration`), DB tables and
> columns, `suggestion.target_entity_type == "role_illustration"`, form param
> namespaces (`illustration[...]`), routes (`/illustrations`,
> `/illustration_archives`), controllers, view classes (`IllustrationFrame`),
> Stimulus controllers and targets, turbo-frame ids (`illustration-<id>`), the
> `illustrations` JSON key in MCP payloads, and the MCP **tool names**
> (`frameworks_archive_illustration`, `frameworks_reorder_illustrations`,
> `calibration_sessions_flag_illustration`). Same split as the assessment
> surface's "Feedback / Evidence" relabel ([assessments.md](assessments.md)):
> when you add a surface, label it "example", keep the identifier
> "illustration". Never use the two interchangeably in copy. The one
> mapping from an entity type to the word a person reads is
> `Frameworks::EntityLabels` — used by the suggestion badges AND by the
> aggregate's and Operations' error messages, which reach flash alerts, so
> a failed write can never leak the raw `role_illustration` identifier. The
> deliberate exception is a message naming an *invalid* value a caller
> supplied ("Unknown entity type: x") — echo the identifier there.

## Where everything lives

This guide is the entry point; it loads whenever you open a file under `app/views/frameworks/` or `app/controllers/frameworks/`. The rest is split by concern so that loading it stays cheap. Section (§) and lesson numbers are unchanged from the single-file guide, so a code comment citing "framework-explorer.md §11a" or "Hard-Won Lesson 23" still finds its target through this table.

| Read | When you are about to… | Holds |
|---|---|---|
| this file | change anything in the explorer | Overview, architecture, §1–§7 (role tree, filters, URL state, responsive layout), sticky positioning, activity feed coverage |
| [suggestions.md](framework-explorer/suggestions.md) | change the context pane, the activity feed, pending-change decoration, inline approve / reject, clarifications or suggestion threads | §8, §9, §10, §12, §12a, §13 |
| [editing.md](framework-explorer/editing.md) | add, archive, reorder or rename in edit mode; touch a kebab, the hover cluster or an add affordance; change what a write responds with | §11, §11a, §11b |
| [stimulus-controllers.md](framework-explorer/stimulus-controllers.md) | change a Stimulus controller the explorer uses, or an event it dispatches | Each controller's responsibilities, event contracts |
| [lessons.md](framework-explorer/lessons.md) | touch anything a lesson below names | Hard-Won Lessons 1–40 |
| [file-reference.md](framework-explorer/file-reference.md) | look for the file that owns something | File Reference |

### Hard-Won Lessons — index

Each title is the rule. Read the lesson in [lessons.md](framework-explorer/lessons.md) before changing what it names.

- **1.** Checkbox action binding requires explicit event type
- **2.** Don't use `.closest('.hidden')` for visibility checks
- **3.** Mobile overlay requires inline styles, not class toggling
- **4.** Controller element scope matters for actions
- **5.** Filter illustrations by selected roles in the builder
- **6.** Turbo Frame must be re-fetched on selection change
- **7.** Category row sibling walking
- **8.** Focus pane visibility and URL state are separate concerns
- **9.** Stimulus `this.dispatch(...)` doesn't accept a `target:` option
- **10.** JavaScript ASI bites array literals on new lines
- **11.** Nested `overflow-*` wrappers break sticky headers
- **12.** Tailwind JIT can't see interpolated class names
- **13.** Controller responses that re-render an editable component must pass `mode: :edit`
- **14.** A visible Turbo Frame with `src:` auto-fetches before Stimulus primes
- **15.** Aggregate on-handlers and event data keys drift silently until the aggregate becomes a read source
- **16.** Controller responses that swap an entity frame must re-query the pending count
- **17.** Inline-editing / archiving a draft-added capability must resolve from the graph, not the read model
- **18.** Empty categories must stay visible in edit mode
- **19.** Multiple modals under one `modal` controller need `data-modal-target-id`
- **20.** One endpoint, two surfaces — branch on an explicit marker, not request format
- **21.** A write answers a Turbo Stream or a 204 — never a bare 200, never a redirect
- **22.** The pane's scroll container lives INSIDE the reloaded frame — reloads must preserve it, and feedback must not wait for them
- **23.** Never re-fetch the whole matrix per approval — the edit-mode frame is megabytes
- **24.** A translucent background on a sticky cell is a hole, not a tint
- **25.** The expanded rows are fetched on demand — never render them into the matrix
- **26.** A bodyless 4xx inside a Turbo Frame is a silent failure
- **27.** An editor inside an auto-layout table can only be as wide as its host already is
- **28.** Turbo's submit-end can beat its own frame render — don't drop state on it
- **29.** Delegating a widget is only a win if the trigger stays small
- **30.** A fixed menu should follow its trigger, not dismiss on scroll
- **31.** `position: fixed` escapes clipping, not paint order
- **32.** A `<template>` parses table fragments; `<div>`-wrapping them does not
- **33.** A utility string is paid for per element; a class name once
- **34.** A cache key must move when the code does, and at sub-second precision
- **35.** Turbo re-fetches a same-value `src`, so "skip when unchanged" disables refresh
- **36.** A sticky child moves; its parent's rect does not
- **37.** A closed `Kit::Dropdown` still matches `[role="menu"]`
- **38.** Selenium scrolls bottom-aligned before it acts, so a short scrollport puts a tall row back under the sticky header
- **39.** `pointer-events` inherits, so gating a cluster disarms the menu inside it
- **40.** Announce a draft from the event, not from each write

## Overview

The Framework Explorer is a two- or three-pane interactive view for browsing career frameworks. It renders a **capability x level matrix** filtered by user-selected roles, with a hierarchical role tree for navigation. View mode has two panes (role tree + matrix); edit mode adds a third — the context / suggestions pane on the right.

The explorer has two modes, both backed by the same components:

- **View mode** (`GET /frameworks/:id`) — published state only. No inline editors, no pending-suggestion decorations on the grid, no context pane. The `.flex` layout has two panes (role tree + matrix).
- **Edit mode** (`GET /frameworks/:id/edit`) — contributor workspace. Adds inline-edit pencils on capability name / **capability description** / category / expectation / example text, "+ Add example" affordances, the wiggle on draft (not-yet-published) entities + the pending-archive badge, the amber "Edit mode" header badge, and the context (suggestions/activity) pane on the right. Access requires `FrameworkPolicy#edit?` — collaborator with suggest rights, or tenant admin. **Structural edits** (add capability/category, the draft pill, the Publish button) need the narrower `#edit_structure?` / `#publish?` bar — see §11. The row-actions **Archive** is offered to any suggest-rights viewer (it applies directly or proposes a suggestion per the edit/suggest toggle + authority — §11).

Both modes read structural data from the same `Frameworks::ExplorerGraph` snapshot (see [docs/architecture/framework-edit-mode-benchmarks.md](../architecture/framework-edit-mode-benchmarks.md)). A `mode: :view | :edit` kwarg is threaded from `ShowView` down through `Matrix`, `MatrixCategoryGroup`, `MatrixRow`, `MatrixCell`, and each entity's inline-edit frame. The `MatrixDataBuilder` filters out `added_in_draft` entities in view mode — matching `PublishedState`'s event-deferral semantics from ADR-16.

### Editing vs Suggesting toggle (within edit mode)

A segmented pill in the edit-mode header lets contributors flip between two submodes:

- **Editing** (default): inline edits to capability / category / expectation / illustration text auto-apply for users with approval authority (owner, editor, capability/category lead, role lead — scoped to tier). Non-authority users' changes land as pending regardless.
- **Suggesting**: inline edits always land as pending suggestions, even from authority-holders. Useful when a reviewer wants to propose a change for discussion rather than commit it.

Plumbing:
- Persisted client-side in a 1-year cookie `framework_edit_mode` (`editing` | `suggesting`). Single global cookie — applies across frameworks.
- [`app/controllers/concerns/framework_edit_mode.rb`](../../app/controllers/concerns/framework_edit_mode.rb) reads the cookie server-side and returns `:editing` / `:suggesting`.
- The four inline-edit controllers (`IllustrationsController`, `CapabilitiesController`, `CategoriesController`, `ExpectationsController`) `include FrameworkEditMode` and dispatch the shared [`Operations::Frameworks::SuggestEdit`](../../app/operations/operations/frameworks/suggest_edit.rb) (web + MCP — the `frameworks_suggest_edit` tool is the same code path), passing `mode: framework_edit_mode.to_s`. (`CapabilitiesController#update` **and** `CategoriesController#update` each handle **name or description** — whichever field the inline editor submitted — re-rendering the matching frame. Blank values are rejected as invalid input — the `SuggestedEdit` read model requires a `suggested_value`, so "clear the description" is not expressible as a suggestion.)
- **Consecutive edits by the same author amend, they don't stack.** When the author already has a *pending* edit on the same `(entity, field)`, `SuggestEdit` routes the new value through `#amend_suggestion` (→ `SuggestionAmended`) instead of a second `#suggest_edit`. So in Suggesting mode (and for any non-authority user) a field carries **one** pending suggestion per author — the all-suggestions page and activity feed never show consecutive duplicate suggestions on the same field by the same person; the 2nd+ edit renders as a distinct "Amended a … suggestion" feed entry. (In Editing mode an authority-holder's edit auto-approves immediately, so no pending suggestion lingers to amend — each applied change is its own audit event. Different authors still produce separate pending suggestions on the same field, so the §10 "stacked edits" multi-author case is unchanged.) **The same amend-on-duplicate rule covers `behavioural_expectation` *creates*** authored via "+ Add expectation": `Operations::Frameworks::SetBehaviouralExpectation` amends the author's existing pending create for that cell instead of stacking a second proposal. Because `apply_suggested_creation` reads `proposed_attributes` but an amend only updates `suggested_value`, the amended value is folded back into the content field (`Frameworks::Aggregate::CREATE_CONTENT_FIELD`) at BOTH ends: the aggregate folds at approval so the latest value is applied, and the `PublishedState` projection folds into the read model's `proposed_attributes` at amend time so the ghost/previews display it (they render `proposed_attributes`, not `suggested_value` — before this, an amended ghost kept its original text) — and create/delete proposals are in `ActivityFeedQuery::PROPOSAL_KINDS`, so an amended create supersedes its original feed entry (only the latest stays actionable).
- `SuggestionsController#create` (the explicit "propose a change" endpoint for full-form creates/deletes) is intentionally **not** wired to the toggle — it always submits as pending, dispatching `Operations::Frameworks::{SuggestCreate,SuggestDelete}` (web + MCP — `frameworks_suggest_create` / `frameworks_suggest_delete`). The example "+ Add" path is the one that forwards `framework_edit_mode` into `SuggestCreate` (`mode: "editing"` auto-applies for authority-holders; the tool's default is suggesting).
- Stimulus controller [`edit_mode_toggle_controller.js`](../../app/javascript/controllers/edit_mode_toggle_controller.js) writes the cookie, swaps `aria-pressed` + the caller-supplied active/inactive classes, and dispatches the window-scoped `framework-edit-mode:changed` event so the open editor's Save/Propose label flips without a round trip. The cookie is picked up server-side on the next submission.
- **The mode is visible at the point of action, and honest.** The shared editor's submit button reads **Save** or **Propose** — derived from the viewer's per-entity approval authority (computed server-side into `data-field-editor-approvals-value` on the explorer root, from `Frameworks::SuggestionApprovalAuthority`) AND the current mode; a proposal also tints the textarea amber. Fixed-outcome hosts override the derivation: org-structure renames always say Save (no approval tier exists), an amend of a pending suggestion always says Propose.
- **A viewer who clears no tier gets no toggle.** "Editing" can never be true for them, so `ShowView#edit_suggest_toggle` renders a static "Suggesting" badge (with a tooltip) instead of a choice that does nothing.

After a pending edit, the inline-edit controllers re-query the AR `SuggestedEdit` table and pass `pending_edit_count` into the re-rendered frame, so the amber wavy underline appears immediately in Suggesting mode — the user sees their proposal land without needing a full reload.

**A rejected save is visible, and never eats the typed text.** The four endpoints re-render their own frame at **422 with a body** — a `data-editor-error` message inline in the cell plus the *attempted* value echoed back — and the shared editor re-opens on that host seeded with it. A bodyless 4xx is invisible to Turbo (Hard-Won Lesson 26).

```
+---------------------------+----------------------------------------------+
| Navbar (Home | Framework) |                                              |
+---------------------------+----------------------------------------------+
| Framework Name  v0        | 4 Roles  8 Levels  40 Capabilities           |
+---------------------------+----------------------------------------------+
|  Role Tree (left pane)    |  Capability x Level Matrix (main pane)       |
|                           |                                              |
|  FINANCE                  |  CAPABILITY  | Level 1    | Level 2    | ... |
|    Financial Control      |  ------------|------------|------------|-----|
|      [ ] Accountant       |  > Thinking  | 3 caps     |            |     |
|      [x] FC               |    Strategic | Asks clar- | Identifies |     |
|                           |    Thinking  | ifying ... | root cau-  |     |
|  PRODUCT + ENGINEERING    |              | * 2 ex.    | ses        |     |
|    Product Design         |              |            |            |     |
|      [x] Product Designer |              |            |            |     |
|    Software Engineering   |              |            |            |     |
|      [x] Software Eng.    |              |            |            |     |
|      [ ] Eng. Manager     |              |            |            |     |
+---------------------------+----------------------------------------------+
|  Edit mode only: context (suggestions) pane to the right of the matrix  |
+--------------------------------------------------------------------------+
```

## Architecture

### Hotwire-First Design

The explorer uses a **server-rendered matrix** inside a **Turbo Frame**. Role selection changes trigger a frame fetch — the server re-renders the matrix with filtered data. This keeps rendering logic in Ruby (Phlex) and avoids duplicating data transformation in JavaScript.

Client-side interactivity (row expansion, category collapse, tree toggling) is handled by Stimulus controllers operating on pre-rendered HTML.

```
User toggles role checkbox
  → tree_controller dispatches "tree:changed" event
  → framework_explorer_controller updates role count display
  → matrix_controller builds URL, sets turbo-frame src
  → Server renders MatrixFrameView with filtered data
  → Turbo swaps frame content
```

### Component Hierarchy

```
PageLayout
└── div[data-controller="framework-explorer"]
    ├── framework_header
    │   ├── back link, FrameworkNameFrame (the h1; rename pencil for admin / owner, edit only),
    │   │   version badge, DraftStatus(:badge) + "Edit mode" badge (edit only)
    │   └── right cluster: edit-suggest toggle + mode switcher + DraftStatus(:publish) + settings link
    ├── stats_bar (role count toggle, levels, capabilities; "+ Add category" + Activity toggle w/ PendingCountBadge — edit only)
    ├── FieldEditorTemplate (edit only — the ONE inline-edit <form>, inert in a <template>)
    ├── WriteStatus (edit only — the ONE role="status" toast region every write streams into, §11b)
    ├── ArchiveModal / AddCapabilityModal / AddCategoryModal / ArchiveCategoryModal (edit + can_edit_structure; data-controller="modal")
    ├── ArchiveIllustrationModal (edit only — replaced the menu's native confirm(), §11b)
    │   (root also carries data-controller="field-editor" + "explorer-menu" in edit mode)
    └── explorer_layout[data-controller="matrix"]
        ├── aside[data-controller="tree"]  ← left pane (role tree)
        │   └── RoleTree
        │       └── department groups → family groups → role checkboxes
        ├── div (main pane)
        │   └── turbo-frame#framework-matrix
        │       └── Matrix (table#framework-matrix-table)
        │           ├── MatrixHeader (sticky thead)
        │           └── MatrixCategoryGroup (per category — its OWN tbody#category-group-<id>)
        │               ├── category header row (sticky)
        │               │   ├── chevron button → matrix#toggleCategory
        │               │   ├── CategoryNameFrame (edit: inline editor; view: plain name)
        │               │   └── CategoryDescriptionFrame (edit: inline editor; "Add a description…" when blank)
        │               ├── MatrixRow (per capability)
        │               │   ├── compact row (click → matrix#toggleRow)
        │               │   │   ├── CapabilityNameFrame (edit: inline editor)
        │               │   │   │       + row hover cluster: pencil · discuss · ⋮ (§11a)
        │               │   │   ├── CapabilityDescriptionFrame (edit: inline editor; "Add a description…" when blank)
        │               │   │   └── MatrixCell × N
        │               │   │       ├── ExpectationTextFrame (edit: inline editor)
        │               │   │       └── NewExpectationFrame / PendingExpectationFrame
        │               │   │           (edit: author an empty cell, or its pending ghost)
        │               │   └── ExpandedRow (hidden PLACEHOLDER; content fetched on first expand)
        │               │       └── expanded td (click → matrix#focusCell)
        │               │           ├── IllustrationFrame (edit: pencil + inline editor)
        │               │           ├── PendingIllustrationFrame (ghost; edit mode only)
        │               │           └── NewIllustrationFrame ("+ Add"; edit mode only)
        │               └── "+ Add capability" row (edit + can_edit_structure → opens AddCapabilityModal)
        └── aside[data-controller="context-pane"]  ← right pane (edit mode only)
            └── turbo-frame#suggestion-panel (Activity::PanelFrame — the
                activity feed; Activity::SuggestionCardFrame at suggestion focus)
```

### Data Flow

```
Controller
  → explorer_matrix_etag → fresh_when → 304?              # four cheap reads, before any of the below
  → Frameworks::ExplorerGraph.load(framework_id)          # single indexed jsonb fetch
      (falls back to .rebuild on miss / format bump)
  → MatrixDataBuilder(framework: graph, mode: :view|:edit) # in-memory filter + structure
      — view mode: filter out added_in_draft entities, drop pending-suggestion maps
      — edit mode: include everything, wire pending decorations
      — the matrix: include_illustrations: false (nothing renders them)
      — an expanded row: #build_capability(id), illustrations on, suggestions
        scoped to that capability's entity ids
  → ShowView / MatrixFrameView (renders Phlex components with mode:)
    → Stimulus controllers (manage interactivity)
```

**The read endpoints are conditional (#383).** `#matrix` / `#edit_matrix` /
`#expanded_row` / `#edit_expanded_row` set an ETag over everything the HTML
depends on — the graph snapshot's `updated_at`, the pending-suggestion table's
max `updated_at` + count (edit mode only), the three filter axes, the mode, the
viewer's own permissions, and the running release — **before** the graph load and
the builder, so a filter toggled back to a state the browser already holds costs
neither a download nor a re-parse. Two deliberate holes: the key is skipped in
**development** (code reloading changes the markup without moving any input) and
for a framework with **no persisted graph row** (an AR-only fixture rebuilds the
graph on the fly, and the key can see nothing about those tables' freshness).
The running release comes from `Rails.application.config.x.release_id` —
`RENDER_GIT_COMMIT`, else a per-process token; without it a deploy that changed
the markup would keep being answered from the previous release's HTML. Timestamps
enter the key at **nanosecond** precision: `ActiveSupport::Cache.expand_cache_key`
stringifies a `Time` to whole seconds, so two edits inside the same second once
produced the same key.

**Both filter axes share one debounce.** `matrix#updateSelection` and
`#updateSearch` push the browser URL immediately (the address bar, and the
axis read-back the *next* filter change depends on, must never lag the
controls) but schedule the fetch on one 300ms trailing timer, so a burst of
checkbox clicks — or a role toggle and a search landing together — costs one
fetch. `matrix#refresh` (the §12 fallback) stays immediate. A thin
indeterminate bar (`[data-matrix-target="busy"]`, `.mx-busy`, `role="status"`)
covers the WHOLE wait: Turbo's own `busy` attribute only appears once a request
is in flight, so on its own it would leave the first 300ms looking ignored.

The matrix reads from the `Frameworks::ExplorerGraph` snapshot — a persistent JSON hash tree written atomically after each graph-relevant `Repository#with_framework` command, in the same transaction as its events (comment-only commits skip the rewrite; bulk writers using `Repository#batch` — seeds, imports — defer to ONE write at the end of the unit of work). The explorer no longer eager-loads the `FrameworkState::*` AR tree; that substrate remains for assessments, reporting, HRIS, and the full suggestions index. See `docs/architecture/framework-edit-mode-benchmarks.md` for why (read latency is ~6 ms p50 at Small, ~19 ms at Medium — versus hundreds of ms for AR eager-load or aggregate replay).

`MatrixDataBuilder` is the single source of truth for what the matrix displays. Operates entirely in-memory on the duck-typed graph — no additional queries. Framework size stays in the 100–200 capability / 50–100 role range.

**It builds only what its caller renders (#383).** Two kwargs, both load-bearing:

- `include_illustrations:` — false for the compact matrix, which has rendered no
  illustration data since the expanded row became an on-demand fetch (#378), so
  grouping ~1,000 illustrations by role and walking two pending maps per
  illustration was pure waste. The cell's "N examples" count and its discussion
  total still include them, because both are rendered on the compact cell.
- `#build_capability(id)` — the expanded row's entry point. It applies the same
  visibility rules `#build` applies to all of them (archived category,
  draft-hidden capability, role-family scope, text filter), so a row it returns
  is exactly a row the matrix would have rendered, and the controller scopes the
  pending-suggestion read to that capability's own entity ids
  (`ExplorerMatrix#capability_suggestion_scope`).

Measured on the seeded me&u framework (38 capabilities, 995 illustrations,
11 roles × 8 levels): full build 3.63 ms with illustrations, 2.48 ms without,
**0.17 ms** for one capability.

## Key Design Decisions

### 1. Role Tree: Three-Level Hierarchy

**Department → Role Family → Role**

Departments are a display grouping — a free-text `department` string that is an **event-sourced** property of the role family (`RoleFamilyAdded`/`RoleFamilyUpdated`, projected to the `framework_role_families.department` column). Role families without a department appear ungrouped. Moving a family between departments is just editing the string (no department entity); a brand-new string creates a group, emptying the last family out of one removes it. This mirrors organisational structure without prescribing it. Two edit surfaces (§11): the role-family edit dialog moves **one** family; inline-renaming a **department header** relabels **every** family in that group at once (bulk relabel via `RenameDepartment`).

### 2. Solo Mode

The role tree supports a "solo" interaction (like audio mixing software):
- Click solo on a role → remembers current selection, selects only that role
- Click solo again (or "Show All") → restores the previous selection
- Any manual toggle exits solo mode

This lets users quickly focus on one role then return to comparing multiple roles without re-checking everything.

### 3. Merged Level Columns

Different roles can have different level structures (IC: L1-L8, Manager: L3-L7). The matrix **merges levels by ordinal** — column headers show the union of all ordinals from selected roles, with role-specific level codes as sub-labels.

When few roles are selected (≤ 3), full level titles are shown ("Associate Product Designer"). When many roles are selected (> 3), compact codes are shown ("PD1", "E1") to save space.

### 4. Capability Filtering & Dimming

Not all capabilities apply to all roles. The matrix shows:
- **Full opacity**: capabilities bound to at least one selected role (via `CapabilityRoleBinding`)
- **Dimmed (opacity-50)**: capabilities bound to other roles in the same role families — provides context without noise
- **Hidden**: capabilities from unrelated role families — excluded entirely

### 4a. Text filter (capability search)

A free-text filter in the stats-bar header narrows the matrix to capabilities
matching a query. It is a **second, orthogonal axis** to the role/track filter,
not a replacement — the two compose with **AND** semantics.

- **Composition.** The text filter applies *within* the current role scope. A
  change to one axis preserves the other: `matrix_controller#updateSearch` reads
  the role/track params back from the browser URL before rebuilding the frame
  `src`, and `#updateSelection` reads `q` back the same way. Both end at the
  shared `#rebuildMatrixFrame({ roleIds, track, query })`.
- **Dimming is untouched (layered axes).** A dimmed-but-matching capability
  (bound to a same-family role you didn't select) still renders, still dimmed.
  Search adds a "matches the query" signal on top of the existing
  bound/dimmed/hidden vocabulary — it never changes `bound_to_selected`.
- **Match scope = visible compact surfaces only.** `MatrixDataBuilder#searchable_text`
  matches (token-AND, case-insensitive) against category name/description,
  capability name/description, and **behavioural-expectation text**.
  **Illustrations are deliberately excluded** — they're numerous, verbose, and
  hidden until a row is expanded, so matching them both dilutes results
  (a one-word mention in one example surfaces the whole capability) and produces
  matches the user can't see. Every surface searched is visible in the compact
  matrix, so every match reason is on-screen. A query on a *category* name
  surfaces all of its capabilities (the category text is part of each
  capability's haystack). **In edit mode the proposed values of pending
  suggested edits are folded into the haystack too** (`pending_suggested_values`,
  latest-per-field from the suggestions map), so searching for text that exists
  only in an unapproved proposal still surfaces the capability — the on-screen
  inline diff is the match reason. View mode never sees these (its suggestions
  map is empty).
- **Match highlighting.** Every matched surface marks the query terms with a
  `<mark>` (amber). The `SearchHighlight` concern (`render_highlighted(text,
  query)`) is mixed into the capability-name / category-name / expectation-text
  frames and the capability-description line, and threaded the raw query down
  the render chain (`Matrix → MatrixCategoryGroup → MatrixRow → {CapabilityNameFrame,
  MatrixCell → ExpectationTextFrame}`). It builds Phlex text + `mark` nodes (never
  raw HTML, so the query can't inject markup), token-matches case-insensitively,
  and merges overlapping spans so marks never nest. Highlighting is skipped when
  a pending-edit inline **diff** is being shown for that entity (the diff wins).
- **Live result count lives inside the frame.** The "Showing N of M capabilities
  matching …" banner is rendered by `Matrix` *inside* the Turbo Frame, because
  the stats-bar header sits **outside** the frame and a frame-only reload can't
  update it. (The header's "N Capabilities" stat uses the role-scoped
  `in_scope_capability_count`, which is query-independent, so it stays stable.)
- **No-matches state** offers escapes along both axes — "Clear search" (drop the
  query, keep the role scope) and "Show all roles" (reset both) — each breaking
  out of the frame via `data-turbo-frame="_top"` so the header input + browser
  URL reset cleanly.
- **Interaction.** `framework_search_controller` debounces keystrokes (250ms via
  `useDebounce`) and dispatches a window-scoped `framework-search:changed`
  event; Esc and the inline × clear immediately. `q` is URL-synced alongside
  `roles[]` / `track` for shareable/bookmarkable filtered views. The native
  WebKit search-cancel button is suppressed (`[&::-webkit-search-cancel-button]:appearance-none`)
  so only the custom × shows. On mobile the box drops to its own full-width line
  (`max-sm:w-full` + `flex-wrap` on the stats bar).

### 5. Progressive Disclosure (Three Levels)

1. **Category** — collapsible group header (click to show/hide all capabilities in category)
2. **Row** — compact state shows expectation text per level; click to expand illustrations
3. **Cell** — in compact state, shows expectation + "N examples" indicator badge (plus a separate amber "N pending" pill when ≥2 pending suggestions exist — see §10)

Illustrations appear only in the expanded row, never inline in cells. This keeps the compact matrix dense and scannable.

### 6. URL-Driven State

Selected roles, track filter, and **focus context** are encoded in URL query params:
```
/frameworks/:id?roles[]=uuid1&roles[]=uuid2&track=ic
                &focus=capability&capability_id=<uuid>
                &focus=category&category_id=<uuid>
                &focus=cell&capability_id=<uuid>&level_ordinal=2
```

This enables bookmarking, sharing, and browser back/forward. The server reads role/track params on page load to set initial matrix state; focus params are seeded into `context_pane_controller` which primes the suggestion panel frame so deep links render filtered content.

- `matrix_controller` pushes `roles[]=` / `track=` on every selection change.
- `context_pane_controller` pushes `focus=` / `category_id=` / `capability_id=` / `level_ordinal=` on every focus change and deletes them when focus returns to `framework`.
- The suggestion panel frame's `src` mirrors the browser URL but also carries `layout=panel`. The controller short-circuits when the computed `src` string equals the current `src` — prevents duplicate fetches on no-op role changes at framework focus.

### 7. Responsive Behaviour

**Both side panes are overlays below `lg`; only the matrix ever scrolls
horizontally.** Edit mode originally had no responsive contract at all — it
added a second `w-80` column rendered open, which at 375 px left the matrix a
55 px sliver and pushed the document to 825 px wide (issue #384).

| Viewport | Role tree (view + edit) | Activity pane (edit only) | Matrix |
|----------|-------------------------|---------------------------|--------|
| Desktop (≥ 1024px) | Inline left pane (`w-76` = 19 rem), open | Inline right pane (`w-80`), **open by default** | Between them |
| Mobile (< 1024px) | `max-lg:hidden`; fixed overlay on toggle, left-anchored, `min(24rem, 100vw - 3rem)` | `max-lg:hidden`; fixed overlay on toggle, right-anchored, with its own title bar + × | **Full width** |

**The tree pane is sized from the names it has to hold.** At `w-72` a family's
name box was 175.4 px against a longest name of 171.6 px ("Software
Engineering") — under 4 px of headroom, which is why anything else claiming a
pixel wrapped the tree. `w-76` puts the family box at 191.4 px and the role box
at 207 px (~20 px and ~36 px clear of the seeded framework's longest names), for
16 px of the matrix's 1,112 at 1400 wide. The overlay is wider still
(24 rem, capped at the viewport minus the tap strip): it shares the width with
nothing, so its boxes are 214 px / 230 px.

Both toggles are header stats doing double duty: the **role count** ("4 Roles"
with a chevron) and the **Activity** stat (with its pending-count badge). Each
carries `aria-expanded`.

An overlay pane closes on an outside tap (`useClickOutside`), on Esc
(`framework-explorer#closeOverlayPanes`), and — for the activity pane — on its
own `lg:hidden` ×. A strip of the grid always stays visible beside an open
overlay: it is both the cue that something is covered and the target for the
tap that uncovers it.

**The dismissing tap is consumed.** `useClickOutside` listens on `window` in
the *capture* phase and does not stop the event, so the tap that closes an
overlay used to carry on to whatever it landed on — and the strip left visible
beside the pane is the matrix, so dismissing the feed also expanded a
capability row under it. `#closeIfOutside` stops propagation when it actually
closes something.

**Only one overlay is open at a time.** Both are `z-index: 30` fixed panels, so
a second one opened over the first just buries it — invisible, still "open",
and still the pane Esc closes first. Opening either closes the other
(`#closeOtherOverlay`).

**Both dismissals stand down while a modal or an open menu is up**
(`#somethingElseIsOpen`). This matters more for the tap than for Esc: every
modal is mounted on the explorer ROOT (Lesson 19), so it is *outside* the pane
— without the guard the first tap inside a Reject / Resolve / Add-level dialog
reads as an outside click and quietly closes the feed the reviewer opened it
from.

**Opening the activity overlay moves focus into it**, and closing it by any
path hands focus back to the Activity toggle — the overlay covers the grid, so
Tab must not walk into controls the user can no longer see. Focus *containment*
is deliberately not claimed: the pane stays an `aria-label`led landmark rather
than a `role="dialog"`, and the role tree (unchanged here) behaves as it always
has.

**The height has a floor** (`min-h-80`). `--explorer-offset` is measured, so a
chrome taller than the viewport — reachable at 200% zoom, where the CSS
viewport is ~406 px — would otherwise clamp the calc to zero and leave the grid
with no height at all. With the floor the page scrolls instead: the old
constant's failure mode, and a recoverable one.

**The layout's height is measured, not guessed.** `h-[calc(100dvh -
var(--explorer-offset, 12rem))]`; the shell controller writes
`--explorer-offset` from the layout's own distance to the top of the document
and re-publishes it whenever the chrome resizes (a `ResizeObserver` on the
header) or the window does. The old constant `12rem` only ever described the
desktop header — once it wraps on a phone it is twice that, and the grid hung
below the fold with its sticky header off-screen.

**The phone is a review surface, not an authoring one.** Everything a reviewer
needs — the feed, its actionable entries, the suggestion card, and the reject /
resolve / discuss modals — fits 375 px. The authoring affordances are still
present (the `pointer-coarse` rule in §11a already collapses each cluster to
its kebab), but the structural modals are rendered server-side for every edit-
mode viewer regardless of viewport: the server cannot know the viewport, and
the role-pane flows (add role, add level, edit levels) are reachable on a phone
through the overlay, so gating them on width would remove working functionality.

## Sticky Positioning

The matrix uses a precise z-index hierarchy for sticky elements:

| Element | Position | z-index | Purpose |
|---------|----------|---------|---------|
| Corner cell ("Capability") | `sticky top-0 left-0` | `z-20` | Always visible at intersection |
| Column headers (levels) | `sticky top-0` | `z-10` | Visible when scrolling vertically |
| Category headers | `sticky` + `.mx-cat-row` (`top: var(--matrix-header-h)`) | `z-[5]` | Below column headers, above data |
| Left column (capability name) | `sticky left-0` | `z-[2]` | Visible when scrolling horizontally |

**Every sticky cell must be OPAQUE in both themes (NON-NEGOTIABLE).** A sticky cell is a mask — content scrolls underneath it — so a translucent background (`bg-…/NN`) or a missing one lets that content render straight through. This applies to hover and focus variants too, not just the base class. Where the design wants a tint, use the **opaque composite** (the literal hex of that tint over the surface behind it) rather than the translucent token, so the cell looks identical but actually masks; derive it by compositing in the browser, not by eye, and record the token + surface at the call site. The shared right-edge treatment and the full rationale live in [`concerns/sticky_column.rb`](../../app/views/frameworks/explorer/concerns/sticky_column.rb) — see Hard-Won Lesson 24.

The fills are roles from `theme/roles.css`, shared with the `.mx-*` classes; each tint role is already the opaque composite over the overlay surface.

| Sticky cell | Role | Default (light / dark) |
|---|---|---|
| Header corner + level columns | `bg-overlay-subtle` | gray-50 / the overlay (`#1c2028`) |
| Compact row (capability name) | `bg-overlay`, hover `bg-overlay-hover` | white / `#1c2028`; hover gray-50 / the card at 50% over the overlay |
| Expanded row (empty gutter) | `bg-expanded` | blue-50 at 30% over white / blue-900 at 10% over the overlay |
| Category header row | `bg-overlay-muted` | gray-100 / the card (`#20252e`) |

**The sticky offsets are MEASURED, never constants (NON-NEGOTIABLE).** The
matrix header's height depends on the role selection — ~41 px of code badges
past `MatrixHeader::FULL_TITLE_THRESHOLD`, ~113 px of full level titles (with
their rename pencils in edit mode) at or below it — and the category band's on
whether it carries a description. `matrix_controller#publishStickyGeometry`
measures both with a `ResizeObserver` and publishes them on the explorer root:

| Variable | Measured from | Consumed by |
|---|---|---|
| `--matrix-header-h` | the sticky header **cell** (`thead th`) | `.mx-cat-row`'s `top`, the row's `scroll-margin-top` |
| `--matrix-category-h` | the tallest category band `<tr>` | the row's `scroll-margin-top` |

`.mx-row`'s `scroll-margin-top` is `calc(header + category + 8px)`, so
`scrollIntoView({ block: "start" })` on expand lands the capability name just
below the stack. Both CSS fallbacks are the old constants, so a not-yet-connected
controller is no worse than before. Two rules for anything added here:

- **Measure the sticky BOX, not its parent.** Stickiness lives on the `<th>`s,
  and an element's rect is computed from its normal-flow position — a scrolled
  `<thead>` reports a bottom hundreds of pixels above where its stuck cells
  actually are. The category band's own `<tr>` IS the sticky box, so that one
  reports correctly.
- **Re-observe on frame load.** Both measured elements live inside the matrix
  Turbo Frame, so every filter change replaces them.

**Single scroll container.** The only scroll container is `main_pane` in `show_view.rb` (`flex-1 overflow-auto`, tagged `data-matrix-target="scrollContainer"`). The `<table>` must be rendered as a direct child of the turbo-frame inside it — do NOT wrap it in `overflow-x-auto` (or any `overflow-*`) divs. CSS `position: sticky` anchors to the nearest scrolling ancestor, so a nested overflow wrapper silently captures the anchor and breaks vertical stickiness (see Hard-Won Lesson 11).

## Activity feed coverage (NON-NEGOTIABLE)

The context pane is the framework's **activity feed** — its audit trail and shared
narrative — the direct analogue of the assessment screen's activity feed (see
[assessments.md](assessments.md) → *Activity feed coverage*). Suggested edits were
the first content type; the feed covers the **whole framework lifecycle**.

> **Current state.** The pane renders the full activity feed via
> `Frameworks::ActivityFeedQuery` + `Views::Frameworks::Activity::*`, served by
> `Frameworks::ActivityController#show` (`GET /frameworks/:id/activity`) into the
> `#suggestion-panel` Turbo Frame. Suggestions are one filter group within it
> (chips: All / Suggestions / Edits / Structural / Lifecycle / Collaborators).
> The first increment covers the suggestion lifecycle (submitted / amended /
> approved / rejected / withdrawn), the draft/version lifecycle (draft opened
> incl. `auto_opened`, version published, migration mapping defined), structural
> (capability/category add · archive), editorial (capability / category /
> expectation / illustration updated), and collaborator (added / role changed /
> removed). The feed updates live for every edit-mode viewer (incl. the actor):
> `PublishedState#broadcast_framework_activity` nudges a per-framework Turbo
> stream and `context_pane_controller` reloads the feed frame on the sync signal.
> **The header's "N pending" badge rides the same broadcast** — it sits outside
> the pane's frame, so the pane's reload could never touch it and it kept its
> page-load number until a full reload; header and pane now agree within one
> broadcast (`BroadcastsFrameworkActivity#broadcast_pending_count_badge`).
> **Recency cap + load-older:** the feed reads only the most-recent
> `ActivityFeedQuery::STREAM_READ_LIMIT` events; when more exist *at framework
> focus*, a "Load older activity" footer appends the next (older) batch via a
> Turbo Stream and bumps the running count — cursor-paginated on `before:` (the
> oldest loaded event id) with a `loaded` running total. `activity_more_controller`
> issues the request; a live broadcast reload resets to the most-recent batch.
> Role-family / role / **level adds** now surface too (structural group,
> framework-level anchor; the level entry names its role — "Added L4 to EM ·
> Engineering Manager"), as does the **framework rename** (`framework_renamed`,
> edits group, framework-level anchor, naming the new name). Collaborator entries name the person they concern
> ("Added Cora Puddleduck as editor" — `collaborator_name` resolved from the
> event's person_id, falling back to the anonymous phrasing for unresolvable
> history). Illustration entries — suggestions AND direct edits — locate their
> full (capability × level × role) cell on the context line
> ("Thinking · Strategic Thinking · L2 · E · Software Engineer"), and any
> entry that knows its level carries **cell-level** navigation coords
> (`nav_level="cell"` + `nav_level_ordinal`), so clicking it lands on the
> specific cell rather than just expanding the capability row. **Suggestion discussion threads are wired**:
> `suggestion_commented` entries surface under the suggestions chip (thread
> edits/deletes stay thread-only — the feed shows conversation activity, not
> comment meta-history), and every suggestion-anchored entry carries a
> discussion affordance (comment count + latest excerpt) that opens the pane's
> suggestion card. **Clarifications surface too** (`clarification_requested`
> with the question as the secondary line + an authority-gated "Resolve…"
> action, `clarification_resolved` with the note — suggestions chip,
> cell-anchored with the level pinned; see §12a).
>
> **The auto-approve chain collapses.** An edit made in editing mode by someone
> with approval authority applies immediately, but the domain records the whole
> trail — `EditSuggested` → `SuggestionApproved` (the command handler's own
> `Frameworks::CommandHandler::AUTO_APPROVAL_COMMENT`) → the `*Updated` that
> applied it. Rendered literally, the explorer's commonest action produced
> **three** entries and buried everything else, so `ActivityFeedQuery` emits
> only the applied-change entry. It collapses **only when that entry is in the
> batch** (same `correlation_id`): if the applied change is an event the feed
> doesn't surface, or has scrolled past the read cap, collapsing would delete
> the action from the feed rather than de-duplicate it. A *human* approval keeps
> all three entries — the comment is the only thing that separates the two. The
> events are untouched; the suggestion stays reachable from the standalone
> index. Still deferred (note when adding): reorders. The
> historical `Suggestions::PanelFrame` + `FocusedSuggestionsQuery` remain for the
> standalone suggestion index, not the pane.

**Every action a user can take on a framework MUST be represented in the
activity feed.** For most actions that means an entry of its own; mutations
of an existing comment (edit / delete) instead update or tombstone the
representation the original post already has — the feed shows conversation
activity, not comment meta-history, matching the assessment feed. That includes the full suggestion lifecycle (submitted /
amended / approved / rejected / withdrawn / **commented**), direct editorial
edits, structural changes (capability/category/role/level/binding add · archive ·
reorder), the draft lifecycle (**draft opened** — incl. `auto_opened` —, **version
published**, **migration mapping defined**), and collaborator add / change /
remove. When you add a new framework action you add its feed entry in the same
change:

1. **Source the entry** — from the framework RES stream
   (`Frameworks::ActivityFeedQuery#stream_events`) or a read model. Prefer the
   stream for events with no standalone read-model row (draft opened, version
   published, suggestion approved/commented, migration mapping defined).
2. **Anchor it** to the affected `(category / capability / expectation / level)`
   coordinates so the existing focus protocol (`matrix:focus-changed` +
   `FocusedSuggestionsQuery`-style in-memory `Set` filtering) narrows it. Honour
   the same collaborator visibility gate as neighbouring entries. Framework-level
   events (draft/version/collaborator) carry no matrix coordinates and surface
   only at framework focus — mirroring how `role` / `role_family` / `level`
   suggestions already behave (§9, entity coverage).
3. **Register the kind** in `Views::Frameworks::Activity::Entry` — `KIND_DOT`
   (colour), `KIND_GROUP` (filter chip: suggestions / edits / structural /
   lifecycle / collaborators), and summary + secondary text. Never surface
   internal categorisations (review tiers T1/T2/T3, entity type codes) — they
   serve the system, not the user (§9).
4. **Broadcast the sync signal** from the projection that materialises the action
   so the feed updates **live for everyone including the actor** (the actor's own
   entry is exempt from self-suppression, exactly like the assessment feed).
   Guard the broadcast with `Projections::Replayer.replay_mode?` so rebuilds stay
   silent (see [event-sourcing.md](event-sourcing.md)).
5. **Cover it** in `test/queries/frameworks/activity_feed_query_test.rb` (entry
   emitted, anchored to the right coordinates, visibility-gated) and assert its
   `KIND_GROUP` so it lands under the intended filter.

A new framework action with no feed entry is an incomplete feature, not a
follow-up.

Each content type follows the same row principles: no internal categorisations in
the UI, always show where-in-the-framework context, never truncate the context
line (§9).

## Keeping This Guide Current

Update the file that holds the section — see *Where everything lives* above — whenever the explorer's architecture, interaction patterns, components or Stimulus controllers changes:

- **New design decisions** — add with rationale to the file for that concern, and to the map if it starts a new one
- **Bug fixes revealing non-obvious behaviour** — add to the lessons file, at the next number, and add its title to the index above
- **New or modified components** — update the file reference
- **New Stimulus controllers or changed responsibilities** — update the Stimulus controllers file

Never renumber a section or a lesson: code comments and other guides cite them. Keep this entry point small enough to load on every visit; a concern that grows large moves to its own file. `test/integration/agent_guidance_test.rb` fails when what one directory loads passes 100k characters (this core, plus the guides of every directory above it), and when any guide passes Claude Code's 150k per-file limit.

If a lesson or decision is superseded, update or remove the old entry rather than appending a contradiction.
