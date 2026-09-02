# Framework Explorer — UX Design & Architecture

This document captures the design decisions, interaction patterns, and hard-won lessons from building the Framework Explorer. Consult this before modifying the explorer or building features that extend it.

> **See also:** [assessments.md](assessments.md) for the assessment extension of the matrix pattern.

## Overview

The Framework Explorer is a two- or three-pane interactive view for browsing career frameworks. It renders a **capability x level matrix** filtered by user-selected roles, with a hierarchical role tree for navigation. View mode has two panes (role tree + matrix); edit mode adds a third — the context / suggestions pane on the right.

The explorer has two modes, both backed by the same components:

- **View mode** (`GET /frameworks/:id`) — published state only. No inline editors, no pending-suggestion decorations on the grid, no context pane. The `.flex` layout has two panes (role tree + matrix).
- **Edit mode** (`GET /frameworks/:id/edit`) — contributor workspace. Adds inline-edit pencils on capability name / **capability description** / category / expectation / illustration text, "+ Add illustration" affordances, the wiggle on draft (not-yet-published) entities + the pending-archive badge, the amber "Edit mode" header badge, and the context (suggestions/activity) pane on the right. Access requires `FrameworkPolicy#edit?` — collaborator with suggest rights, or tenant admin. **Structural edits** (add capability/category, the draft pill, the Publish button) need the narrower `#edit_structure?` / `#publish?` bar — see §11. The row-actions **Archive** is offered to any suggest-rights viewer (it applies directly or proposes a suggestion per the edit/suggest toggle + authority — §11).

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
- `SuggestionsController#create` (the explicit "propose a change" endpoint for full-form creates/deletes) is intentionally **not** wired to the toggle — it always submits as pending, dispatching `Operations::Frameworks::{SuggestCreate,SuggestDelete}` (web + MCP — `frameworks_suggest_create` / `frameworks_suggest_delete`). The illustration "+ Add" path is the one that forwards `framework_edit_mode` into `SuggestCreate` (`mode: "editing"` auto-applies for authority-holders; the tool's default is suggesting).
- Stimulus controller [`edit_mode_toggle_controller.js`](../../app/javascript/controllers/edit_mode_toggle_controller.js) writes the cookie and swaps `aria-pressed` + the caller-supplied active/inactive classes when clicked. No server round-trip on select; the cookie is picked up on the next form submission.

After a pending edit, the inline-edit controllers re-query the AR `SuggestedEdit` table and pass `pending_edit_count` into the re-rendered frame, so the amber wavy underline appears immediately in Suggesting mode — the user sees their proposal land without needing a full reload.

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
    │   ├── back link, framework name, version badge, draft pill + "Edit mode" badge (edit only)
    │   └── right cluster: edit-suggest toggle + mode switcher + Publish button (edit + can_publish) + settings link
    ├── stats_bar (role count toggle, levels, capabilities; "+ Add category" + "N Suggestions" toggle — edit only)
    ├── ArchiveModal / AddCapabilityModal / AddCategoryModal / ArchiveCategoryModal (edit + can_edit_structure; data-controller="modal")
    └── explorer_layout[data-controller="matrix"]
        ├── aside[data-controller="tree"]  ← left pane (role tree)
        │   └── RoleTree
        │       └── department groups → family groups → role checkboxes
        ├── div (main pane)
        │   └── turbo-frame#framework-matrix
        │       └── Matrix
        │           ├── MatrixHeader (sticky thead)
        │           └── MatrixCategoryGroup (per category)
        │               ├── category header row (sticky)
        │               │   ├── chevron button → matrix#toggleCategory
        │               │   ├── CategoryNameFrame (edit: inline editor; view: plain name)
        │               │   └── CategoryDescriptionFrame (edit: inline editor; "Add a description…" when blank)
        │               ├── MatrixRow (per capability)
        │               │   ├── compact row (click → matrix#toggleRow)
        │               │   │   ├── CapabilityNameFrame (edit: inline editor) + archive kebab (hover)
        │               │   │   ├── CapabilityDescriptionFrame (edit: inline editor; "Add a description…" when blank)
        │               │   │   └── MatrixCell × N
        │               │   │       └── ExpectationTextFrame (edit: inline editor)
        │               │   └── expanded row (illustrations, hidden)
        │               │       └── expanded td (click → matrix#focusCell)
        │               │           ├── IllustrationFrame (edit: pencil + inline editor)
        │               │           ├── PendingIllustrationFrame (ghost; edit mode only)
        │               │           └── NewIllustrationFrame ("+ Add"; edit mode only)
        │               └── "+ Add capability" row (edit + can_edit_structure → opens AddCapabilityModal)
        └── aside[data-controller="context-pane"]  ← right pane (edit mode only)
            └── turbo-frame#suggestion-panel (Suggestions::PanelFrame)
```

### Data Flow

```
Controller
  → Frameworks::ExplorerGraph.load(framework_id)          # single indexed jsonb fetch
      (falls back to .rebuild on miss / format bump)
  → MatrixDataBuilder(framework: graph, mode: :view|:edit) # in-memory filter + structure
      — view mode: filter out added_in_draft entities, drop pending-suggestion maps
      — edit mode: include everything, wire pending decorations
  → ShowView / MatrixFrameView (renders Phlex components with mode:)
    → Stimulus controllers (manage interactivity)
```

The matrix reads from the `Frameworks::ExplorerGraph` snapshot — a persistent JSON hash tree written atomically after each graph-relevant `Repository#with_framework` command, in the same transaction as its events (comment-only commits skip the rewrite; bulk writers using `Repository#batch` — seeds, imports — defer to ONE write at the end of the unit of work). The explorer no longer eager-loads the `FrameworkState::*` AR tree; that substrate remains for assessments, reporting, HRIS, and the full suggestions index. See `docs/architecture/framework-edit-mode-benchmarks.md` for why (read latency is ~6 ms p50 at Small, ~19 ms at Medium — versus hundreds of ms for AR eager-load or aggregate replay).

`MatrixDataBuilder` is the single source of truth for what the matrix displays. Operates entirely in-memory on the duck-typed graph — no additional queries. Framework size stays in the 100–200 capability / 50–100 role range.

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

### 8. Focus Context (Context Pane)

**Edit mode only.** The context pane does not render in view mode — viewers see no "N Suggestions" toggle and no right-hand pane. View mode is "published state, clean"; collaborative chatter lives behind `/edit`.

The right-hand context pane (`#suggestion-panel` Turbo Frame) narrows its contents to the currently focused scope. There are four focus levels, each narrower than the previous:

| Level | Trigger | Clear |
|-------|---------|-------|
| `framework` (default) | No explicit action | — |
| `category` | Click the category **name** (chevron still collapses) | Re-click name, or "Show all" |
| `capability` | Expand a row | Collapse the row, or "Show all" |
| `cell` | Click an expanded-row cell | Re-click same cell (→ capability), collapse row (→ framework), or "Show all" |
| `suggestion` | Click a feed entry's **discussion affordance** (count + latest excerpt, or "Discuss") | "← Back to activity", or any explicit matrix focus action |

**Suggestion focus swaps the pane's content, not just its filter**: instead of
the feed, the frame renders the **suggestion card**
(`Views::Frameworks::Activity::SuggestionCardFrame`) — the proposal (values,
rationale, author), its resolution state, the §12 inline Approve / Reject
machinery, and the **discussion thread** with composer. Suggestion management
happens next to the matrix context rather than on a separate page (the detail
page remains as the full-page escape hatch and renders the same Thread
component). `focus=suggestion&suggestion_id=` is URL-synced and deep-linkable
like every other level. Opening the card deliberately does NOT navigate the
matrix — a `matrix:focus-changed` dispatch would immediately overwrite the
focus; the entry's row body remains the way to jump the grid to the entity.

**Panel header is focus-driven**: `FocusedSuggestionsQuery#descriptor` renders the focus title ("All framework suggestions" / "`<Category>` — category" / capability / "`<Capability>` × L`<n>`") and the server-rendered `clear_path` powers the "Show all" link. See §9 for full header/row anatomy.

**Single-scope accordion**: at most one focus scope is active. Focusing a new row clears any prior cell focus. Collapsing a row clears cell focus.

**Role filter layering**: role selection always applies, but only to `role_illustration` rows in the panel. Higher-level entity types (capability, category, expectation) are unaffected by the roles filter — those are framework-level constructs.

**Server-side filtering**: `Frameworks::FocusedSuggestionsQuery` walks eager-loaded framework associations once and builds in-memory `Set`s of in-scope IDs (category / capability / expectation / illustration). No denormalized columns or migrations on `framework_suggested_edits`. The framework read model is small enough (100-200 capabilities) that in-memory resolution is cheap.

**Pane default visibility**: in edit mode the pane is open by default — contributors are usually here *because* of the suggestion feed. Within edit mode, focus actions still never auto-close or re-open the pane; the user can collapse it with the "N Suggestions" toggle and it stays collapsed until they reopen. The no-auto-open rule remains valid inside the mode (focus is an invisible background state until visible); it no longer needs to justify a closed default.

### 9. Context Pane Row Presentation

Each suggestion row in the panel must answer three questions at a glance: **what kind of entity**, **what action**, and **where in the framework**. Internal categorisations (review tiers, entity type codes) are never shown — they serve the system, not the user.

**Panel header** (rendered by `PanelFrame#header`):
- **Focus title** — derived from `FocusedSuggestionsQuery#descriptor`:
  - `:framework` → "All framework suggestions"
  - `:category` → "`<Category>` — category"
  - `:capability` → capability name
  - `:cell` → "`<Capability>` × L`<n>`"
- **Pending count** — "N pending" subtext (counted after status filtering, see below).
- **"← Show all framework suggestions"** clear-focus link — only rendered when focus is not `:framework`. The server passes a `clear_path` that drops focus params; clicking it navigates via the `suggestion-panel` Turbo Frame and fires `click->context-pane#clearFocus` to keep the browser URL in sync.
- **"View all"** link (top-right) — breaks out of the frame via `data-turbo-frame="_top"` to the full suggestion index.

**Row anatomy (top to bottom):**
1. **Two badges** on the same line as the (hover-revealed) detail arrow — entity type in blue, change kind (Edit / New / Delete) in neutral/green/amber. Entity labels come from `Suggestions::IndexView::ENTITY_TYPE_LABELS`.
2. **Context line** — full-width, never truncated. Locates the suggestion within the framework hierarchy. Content varies by entity type *and kind*:
   - *Illustration*: "Role Name · Level Title" (e.g. "Software Engineer · Engineer II"). Falls back to "Role Name · Level N" when no matching level title is found.
   - *Expectation*: "Capability Name · Level N" (e.g. "Strategic Thinking · Level 2").
   - *Capability edit/delete*: "Capability `<field>`" (e.g. "Capability description"). **Creates render no context line** — the capability name appears in the preview.
   - *Category edit/delete*: "Category `<field>`". Creates render no context line.
   - *Role / Role family / Level suggestions*: no context line (these appear only at framework focus — see entity coverage below).
3. **Preview text** — the proposed value (edit), proposed content (create), or current value (delete). Clamped to 2 lines. For creates, `PanelFrame#creation_preview` picks the first present value from a preferred set of content keys so previews read as names/descriptions rather than raw IDs.

**Empty state**: when no suggestions match the current filter, the body renders "No pending suggestions." in a centred panel. The header (title, count "0 pending", "Show all" link if focused, "View all") still renders.

**Entity type coverage**: the four matrix-anchored types — Illustration, Expectation, Capability, Category — match at every focus level. `role`, `role_family`, and `level` suggestions are served by `FocusedSuggestionsQuery` **only at framework focus** (`match?` else-branch) because they have no matrix coordinates to narrow against.

**Key principles:**
- Only pending suggestions render (`PanelFrame#pending` filters `status == "pending"` client-side after the query returns). Approved/rejected/withdrawn are visible only via "View all".
- Never show review tiers (T1/T2/T3) — these are internal approval routing, not user context.
- The context line gets its own full-width row, never sharing with badges. Long capability or role names must remain readable.
- Both role AND level are required for illustrations — role alone doesn't identify the seniority band; level title alone may not identify the role.
- Context labels are resolved in-memory by `FocusedSuggestionsQuery#context_labels` from eager-loaded framework associations; no extra queries.

**Row click behaviour:**
- Clicking the suggestion body (context + preview) navigates the explorer matrix to the relevant entity — expands the capability row, scrolls it into view, and sets the focus context. This lets the user see the suggestion *in the grid* before deciding to act.
- A separate detail-page link (arrow icon, visible on hover) navigates to the full suggestion detail view via `data-turbo-frame="_top"`.
- Navigation coordinates are pre-computed server-side by `FocusedSuggestionsQuery#navigation_coords` and rendered as `data-nav-*` attributes on the row body. The `context_pane_controller` dispatches `suggestion:navigate` on click; `matrix_controller` listens and programmatically expands + scrolls. Rows without resolvable coordinates (e.g. role/family/level at framework focus) render without the `nav_*` data attributes and are non-interactive for navigation.

### 10. In-Matrix Suggestion Indicators

**Edit mode only.** In view mode the controller passes an empty pending-suggestion map to `MatrixDataBuilder`, so none of the indicators below render on the grid. View mode is the published-state-as-published view.

In edit mode, suggestions surface directly on the grid — not just in the context pane. The explorer has a shared visual vocabulary for "this entity has a pending change" with the proposal itself visible inline.

**Pending-change vocabulary (NON-NEGOTIABLE): the wiggle is the universal "differs from published" signal — never a pill.** The amber wavy underline ("the wiggle", `PENDING_EDIT_CLASSES`) marks any text that is **not in the published framework**, whether it's a pending suggestion *or* a change already applied into the open draft (added/edited in draft, not yet published). Do **not** add a "New in draft"/"Draft"/"Unpublished" pill or badge for this — the wiggle says it. Apply it via `suggestion_text_classes(added_in_draft: …)` (it returns the wiggle for `added_in_draft` just as it does for a pending edit), and pair it with `draft_change_title(added_in_draft)` so the meaning is conveyed non-visually (a `title` tooltip — accessibility, since the wiggle is otherwise colour/decoration-only). The one explicit badge that remains is **"Pending archive"**, because *removal* is a distinct state (the row is also struck through), not merely "differs from published". Open **clarifications** are the other deliberate exception — they propose nothing, so they carry a speech-bubble **content glyph**, never the wiggle (see §12a).

**Inline diff (primary affordance for text edits).** When an entity has a pending `kind: "edit"` on its text field, the entity re-renders as a character-level diff over the original text:

- **Added graphemes** — light-blue wavy underline (`PENDING_ADD_CLASSES`, `decoration-sky-400 decoration-wavy`).
- **Removed graphemes** — strikethrough (`PENDING_REMOVE_CLASSES`).
- When the diff exceeds `Frameworks::SuggestionDiff::MAX_CHANGE_RUNS` (3 change runs), the interleaved view is too dense to scan — we fall back to rendering just the proposed value styled with `PROPOSED_TEXT_CLASSES` (same sky-blue wavy underline, no strikethrough). Readers can still open the context pane for the full side-by-side.

The diff operates on grapheme clusters (not bytes), so emoji and combining accents count as single characters. Whitespace-only diffs (trailing trim, double-space collapse) are treated as no-ops and render plain proposed text.

See `app/models/frameworks/suggestion_diff.rb` for the algorithm and `test/models/frameworks/suggestion_diff_test.rb` for the cases that pin down its behaviour.

**Stacked edits.** When an entity has multiple pending edits, the inline diff renders the **most recent** suggestion, and `MatrixCell`'s existing "N pending" pill (below) remains the signal that more proposals exist on the same expectation. Reviewers click through to the context pane to see the stack.

**Decoration concern** (`app/views/frameworks/explorer/concerns/suggestion_decoration.rb`) — shared styling tokens + the `render_inline_diff(original:, pending_edit:)` Phlex helper:
- `PENDING_ADD_CLASSES` — light-blue wavy underline for added graphemes + the fallback proposed-only view.
- `PENDING_REMOVE_CLASSES` — strikethrough for removed graphemes.
- `PROPOSED_TEXT_CLASSES` — alias of `PENDING_ADD_CLASSES`, used for the fallback.
- `PENDING_DELETE_CLASSES` — red strikethrough on the entity wrapper (applied when `pending_delete_count > 0`). Delete wins over edit if both are non-zero.
- `PENDING_EDIT_CLASSES` — the amber wavy underline ("the wiggle"), the universal "differs from published" signal. Returned by `suggestion_text_classes` for both **`added_in_draft`** entities (the draft capability name / expectation text / binding role — replacing the old "New in draft" pill) and the wrapper-level fallback when an entity has a pending edit but no `pending_edit` diff payload. Pair with `draft_change_title(added_in_draft)` for the a11y tooltip.

**Where the inline diff is applied** — six sites, each fed by `MatrixDataBuilder` from the `pending_suggestions` map `{ count:, latest_by_field: { field => descriptor } }`. The map tracks the latest pending edit **per field** (not one field per entity), so a category's (and capability's) name AND description each decorate independently:

| Component | Decorated text | Count source | Diff payload source |
|-----------|----------------|--------------|---------------------|
| `MatrixCategoryGroup` → `CategoryNameFrame` | Category name (sticky category header) | `category_data[:pending_suggestion_count]` | `category_data[:pending_edit]` (field `name`) |
| `MatrixCategoryGroup` → `CategoryDescriptionFrame` | Category description (sticky category header, under the name) | `category_data[:pending_suggestion_count]` | `category_data[:description_pending_edit]` (field `description`) |
| `MatrixRow` → `CapabilityNameFrame` | Capability name (compact row, sticky left column) | `capability_data[:pending_suggestion_count]` | `capability_data[:pending_edit]` (field `name`) |
| `MatrixRow` → `CapabilityDescriptionFrame` | Capability description (compact row, under the name) | `capability_data[:pending_suggestion_count]` | `capability_data[:description_pending_edit]` (field `description`) |
| `MatrixCell` → `ExpectationTextFrame` | Expectation text (compact cell) | `cell_data[:pending_suggestion_count]` | `cell_data[:pending_edit]` (field `description`) |
| `MatrixRow` → `IllustrationFrame` | Illustration text (expanded row) | `cell_data[:illustration_pending_edits][illustration_id]` | `cell_data[:illustration_pending_edit_details][illustration_id]` |

**InlineIndicator pill** (`app/views/frameworks/suggestions/inline_indicator.rb`) — small amber "N pending" count badge. Currently rendered **only** by `MatrixCell`, and **only** when `pending_suggestion_count >= 2`. With the inline diff visible, the pill's job shifts: it tells reviewers that more proposals exist on this expectation than the one currently shown interleaved. Category / capability / illustration rows do not render the pill.

**Ghost entries for pending-create illustrations** (`app/views/frameworks/explorer/pending_illustration_frame.rb`) — pending `role_illustration` creates render inline in the expanded row as amber-wavy-underlined list items alongside the real illustrations for that role (creates have no "original" to diff against, so they keep the original amber-wavy styling). They carry the same pencil-icon affordance as real illustrations: the suggestion's original author can amend the pending proposal; other collaborators submit an alternative suggestion.

**Controller-side hydration after a submit.** When an inline edit lands via one of the four edit controllers (`IllustrationsController`, `CapabilitiesController`, `CategoriesController`, `ExpectationsController`), the re-rendered turbo-frame response re-queries the latest pending `SuggestedEdit` for the entity and passes it in as `pending_edit:`, so the inline diff appears immediately in Suggesting mode without a page reload. Hard-Won Lesson 16 (controller responses must re-query the pending count) now extends to the latest edit's `suggested_value` as well.

**Data source invariants** — all pending counts *and* the per-field `latest_by_field` descriptors are pre-aggregated by `FrameworksController#build_suggestions_map` (via `#load_pending_suggestion_maps`) in a single indexed pass over `framework_suggested_edits`. `MatrixDataBuilder` and every view component operate in memory; no view queries the database for suggestion data.

**The squiggle is clickable — it opens the suggestion card.** Every decorated
pending change (the inline diff, the fallback proposed-text view, and the
pending-create ghosts) is wrapped in
`SuggestionDecoration#with_suggestion_click_affordance`: clicking the squiggled
text dispatches `matrix#openSuggestionCard` → the window `suggestion:open-card`
event → the context pane swaps to that suggestion's card (approve / reject +
thread), revealing the pane if it was collapsed. `stopPropagation` keeps the
click from also toggling the row / focusing the cell. Added-in-draft wiggles
have no suggestion to open and render undecorated-for-click.

**Inline editor seeds with the pending proposal.** When a field has a pending edit, opening its inline editor pre-fills the textarea with the **proposed** value (not the persisted one), so the user refines the proposal that's already shown as the diff — see the shared `inline_editable.rb#inline_editor_value(current_value, pending_edit)` helper, used by every inline-edit frame (capability name + description, category name, expectation text, illustration). The `inline_editor_controller`'s cancel restores the textarea to this server-rendered `defaultValue`, so cancel returns to the proposal too.

### 11. Structural editing (add / archive / publish)

Edit mode exposes direct structural edits, gated on a **narrower bar than the
suggest bar**: `FrameworkPolicy#edit_structure?` (owner / editor / leads, or
tenant admin) — distinct from `#edit?` (any collaborator with suggest rights,
which is all that's needed to *reach* edit mode). The controller computes it
once and threads it as `can_edit_structure` through `ShowView → Matrix →
MatrixCategoryGroup → MatrixRow`. `#publish?` is narrower still (owner / editor).

**Affordances:**
- **"+ Add category"** — in the stats bar (header). Opens the add-category modal.
- **"+ Add capability"** — at the foot of each category group. Opens the
  add-capability modal, prefilled with that category; it captures name +
  description + which **roles** the capability applies to. **At least one role
  is required** (a capability bound to no role is hidden from the role-filtered
  matrix) — enforced both client-side (the modal blocks submit + shows an inline
  message) and in `AddCapability`.
- **"+ Add expectation"** — inline affordance on an **empty-but-applicable**
  matrix cell (a level the capability's bound roles reach, with no expectation
  yet). `MatrixDataBuilder` emits an `authorable` placeholder cell only in edit
  mode (never view); `MatrixCell` renders the affordance for **any edit-mode
  viewer** (edit mode already requires suggest rights), via `NewExpectationFrame`
  — the same inline-editor toggle as "+ Add illustration". Submits to
  `Operations::Frameworks::SetBehaviouralExpectation`, which **follows the
  suggest/approve path** (routes through `suggest_create`): in editing mode an
  author with expectation-tier approval authority has it applied directly
  (shape-changing → draft), otherwise — or in suggesting mode — it lands as a
  pending `behavioural_expectation` creation suggestion. A *not-applicable* cell
  (no bound selected role at that ordinal) and a *filled* cell are untouched.
  (A directly-applied expectation is draft-deferred from the read model, so its
  inline edit resolves from the graph — Lesson 17.) A **pending** create renders
  as an **editable ghost** in the cell (`PendingExpectationFrame`, amber wavy
  underline — the explorer's standard pending-change signal, no extra label) —
  so a proposed expectation shows in the grid, not just the feed — via
  `MatrixDataBuilder`'s `pending_expectation_creates` map (keyed by
  `[capability_id, level_ordinal]`). An expectation is **singular per cell**, so
  while a proposal exists the cell shows the ghost with a hover **pencil**
  (amend — author — / suggest alternative — others) and **no "+ Add
  expectation"** affordance; the pencil's form re-submits to the same create
  endpoint, which amends the author's own proposal or records a non-author's
  alternative. Approve/reject stays in the actionable feed.
- **Row-actions kebab (⋮) → Archive** — hover-revealed beside the capability-name
  pencil; offered to **any suggest-rights (edit-mode) viewer**, not just
  edit-structure holders. "Archive" is the single removal operation — there is no
  separate "delete". Opens the archive modal; the `Operations::Frameworks::ArchiveCapability`
  operation then decides, from the **edit/suggest toggle + the viewer's
  authority** (mirroring inline edits), whether it **applies directly**
  (editing + can-approve-capability → `archive_capability`, one `CapabilityArchived`)
  or lands as a **pending archive suggestion** (suggesting, or no approval rights
  → `suggest_delete`, which on approval runs the same `archive_capability`). The
  modal captures the migration mapping **as-we-go** (Evolve / Archive; *split* is
  a separate future action) when the actor can define one (owner/editor);
  otherwise it's optional/deferred to the publish gate. Once **directly** staged,
  the capability keeps its **"Pending archive" badge** AND the whole row renders
  **struck through** (red line-through, edit mode only — see
  `MatrixRow::STRIKETHROUGH_CLASSES`, applied per-cell via `[&>td]:` because
  `text-decoration` doesn't propagate reliably from a `<tr>` to its cells). View
  mode shows the capability un-struck (it's still in the published version until
  publish). *(Illustrations get the same unified, toggle-driven Archive — an
  **Archive… item in each illustration's ⋮ kebab** in the expanded row
  (`IllustrationFrame#actions_kebab`, per the kebab-right-most rule in
  phlex-views.md) → `Operations::Frameworks::ArchiveIllustration`: direct
  `remove_role_illustration` vs `suggest_delete("role_illustration")`, no
  migration mapping since illustrations carry no ratings.)*
- **Illustration ↑/↓ reorder chevrons** — hover-revealed on each illustration
  in the expanded row, next to the pencil/archive (edit +
  `can_edit_structure`, list >1). Display-order only → **shape-preserving,
  applies live**. The `reorder-list` Stimulus controller (on the per-role
  `<ul>`) POSTs a neighbour-relative move (`{ illustration_id, target_id,
  placement }`) to `IllustrationReordersController`, which translates it into
  the complete ordered list for the shared
  `Operations::Frameworks::ReorderIllustrations` (web + MCP — the MCP tool
  takes the full list, no N-swap dance). On a 204 the controller moves the
  frame's DOM node in place — **no matrix refresh**, so the expanded row and
  scroll position survive repeated moves; other viewers pick the order up on
  their next interaction (feed-live / matrix-not, Lesson 21). The Operation
  and the aggregate both refuse any list that isn't an exact permutation of
  that expectation × role's illustrations (a smuggled foreign id would
  silently renumber another expectation's list). Surfaces in the feed as
  `illustration_reordered` ("Reordered the E · Software Engineer
  illustrations", edits group).
- **Category ↑/↓ reorder chevrons** — hover-revealed on the category header
  next to the archive control (edit + `can_edit_structure`; each direction
  only when a **visible** neighbour exists — role/search filters can hide
  categories, and a move is relative to what the viewer sees). Shape-
  preserving, applies live. Each chevron is a `reorder-move` button POSTing
  the neighbour-relative move to `CategoryReordersController`, which
  re-inserts the category next to that neighbour within the full active order
  and dispatches `Operations::Frameworks::ReorderCategories` (web + MCP,
  complete-list + permutation-validated like illustrations). On 204 the
  button dispatches `org-structure:updated` → `matrix#refresh` (a category is
  a contiguous *block* of rows — no DOM surgery), so neighbour ids re-render
  fresh after every move. Graph + AR read models sort categories
  nil-ordinal-LAST with a stable tiebreak, so a category added after a
  reorder lands at the end instead of jumping to the front. Feed:
  `category_reordered` ("Reordered the categories", structural group,
  framework-level anchor).
- **Row-actions kebab (⋮) → Move up / Move down** — reorder a capability
  within its category (edit + `can_edit_structure`; items appear only for a
  **movable** neighbour — struck pending-archive rows are skipped and get no
  move items themselves). Same machinery as the category chevrons: a
  `reorder-move` POST to `CapabilityReordersController` → 204 →
  `org-structure:updated` → `matrix#refresh`. The controller and
  `Operations::Frameworks::ReorderCapabilities` (web + MCP) resolve the
  category and its reorderable set from the **ExplorerGraph** — draft-added
  capabilities are first-class in the ordering (Lesson 17) even though they
  have no read-model row until publish (the projection skips them; they sort
  nil-last in the read model after publish until the next reorder).
  Capabilities needed a new `ordinal` column + `CapabilityReordered` event;
  both graph builders and the `CapabilityCategory#capabilities` association
  now sort `[ordinal, insertion]` nil-last. Feed: `capability_reordered`
  ("Reordered the capabilities", structural group, category anchor).
- **Row-actions kebab (⋮) → Edit roles…** — offered to **edit-structure
  holders** (a direct structural edit, like add-capability, not the broader
  suggest bar). Opens the shared **binding-editor modal** whose body is the
  `binding-editor` Turbo Frame: it lists the capability's role bindings (each
  with a weight field + Remove) and an "add role" form offering the roles it
  isn't bound to yet. Re-scoping a capability to roles is the editor's headline
  (a capability bound to no role is hidden from the role-filtered matrix). Each
  action dispatches a shared `Operations::Frameworks::{Add,Update,Remove}CapabilityRoleBinding`
  and re-renders the frame **in place** (the modal stays open for list
  management). Add/remove are shape-changing (auto-open a draft, deferred to
  publish); weight edits are shape-preserving (apply live). Individual tolerance
  is an advanced lever exposed via the Operation/MCP only — no UI field yet.
- **Archive-category kebab** — hover-revealed next to the category **name**
  (not the far right of the full-width header, which scrolls off-screen on a
  matrix with many level columns), **only for an empty category** (the aggregate refuses to archive one
  that still holds active capabilities, so we don't offer it otherwise —
  `MatrixDataBuilder` computes `archivable` against the full, non-role-filtered
  capability set). Opens the archive-category modal — a plain confirm + optional
  reason, with **no migration mapping** (categories carry no ratings).
- **Draft pill** (`vN draft`, teal) + **Publish button** — header, edit-mode +
  draft-open only; Publish links to the publish-review page where mappings are
  validated before the version is cut. (Draft lifecycle: see ADR-16/17.)
- **"+ Add role family" / "+ Add role"** — in the left role tree (edit +
  `can_edit_structure`): "+ Add role family" at the tree foot, "+ Add role" at
  the foot of each family's role list (the parent is implied by placement — no
  family picker), mirroring the matrix's add-category / add-capability split.
  The family modal is the `RoleFamilyEditModal` in **`:new` mode** (same
  name/description/department form + `<datalist>`, POST instead of PATCH) so
  create and edit never drift; the new `AddRoleModal` captures name + code +
  track only — levels are deliberately NOT captured (a role is created light).
  Both dispatch `Operations::Frameworks::{AddRoleFamily,AddRole}` (web + MCP)
  and re-render the `role-tree-families` frame in place, selection preserved.
  **Shape-preserving, applies live** — a family/role without published levels
  changes no rating grid — but the new entity renders as a **ghost**: hidden
  from the view-mode tree, wiggled in the edit-mode tree (see *Ghost
  org-structure entities* below). An empty family shows an explicit "No roles
  yet" line where its "+ Add role" affordance sits.
- **"Add level…" (role-row kebab item)** — on each tree **role row**'s ⋮ menu
  (edit + `can_edit_structure`), NOT the matrix header: a ghost role has no
  columns yet, so the tree is the only surface that can always reach it. (It
  was a standalone hover "+ level" button once — the reserved cluster width
  crushed role names to a few characters, so it moved into the kebab.) Opens
  the `AddLevelModal` prefilled with the role and its next free ordinal (computed
  against the graph, draft levels included); captures ordinal + title + code +
  the entry flag. Dispatches `Operations::Frameworks::AddLevel` (web + MCP) —
  **shape-changing**: the aggregate auto-opens a draft and the level is
  deferred from the published read model until publish, so the parent role
  stays a ghost meanwhile. The submit redirects back to the edit explorer
  (selection preserved via `tree-scope-fields`) so the draft column, the
  draft pill, and the flash land in one render. Duplicate ordinals are blocked
  at three layers: inline in the modal as you type (taken ordinals ride the
  trigger dataset), in the Operation (ParameterError → -32602 for MCP), and in
  the aggregate (serialized against the stream).
- **Role-row kebab (⋮) → Add level… / Edit role… / Edit levels…** — the
  scalable home for the role's actions (edit + `can_edit_structure`; the
  MatrixRow-kebab precedent). **Edit role…** opens the
  `AddRoleModal` in `:edit` mode (name + code + track — one form with create,
  so they can't drift; code/track are dialog-only by design: track is an enum,
  a code edit ripples through the matrix header). **Edit levels…** opens the
  **levels editor** — a binding-editor-style `level-editor` Turbo Frame listing
  the role's levels (graph-sourced, so draft-added levels are editable —
  Lesson 17 — wearing the wiggle): per-row title/code saves, an add row at the
  foot with in-frame error surfacing, and the **entry flag as
  radio-with-clear** ("Set as entry" moves the badge; the controller clears the
  previous holder — a web-layer convenience over the per-level Operation, MCP
  parity untouched). Both surfaces fire `org-structure:updated` on success →
  `matrix#refresh`, since role/level codes render in the matrix header, which
  tree/frame re-renders can't reach. Reordering lands into the levels editor
  next.

**Ghost org-structure entities.** A role with **no published level** (freshly
added live, or its levels still draft-born) — and a family with no such role —
is not visible in the published framework view, so the view-mode tree hides it
(the empty-category rule, Lesson 18, one pane left) and the edit-mode tree
renders it with the wiggle + a tooltip ("Not in the published framework yet…").
Derived, not stored: the `GhostEntities` concern (`published_role?` /
`ghost_role?` / `ghost_role_family?`) computes it from level presence — graph
levels carry `added_in_draft`; AR read-model levels are published by
construction — so ghost state self-clears at publish with no event, flag, or
projection change. The role/family name frames self-compute their ghost
decoration, so controller PATCH re-renders stay decorated for free. The matrix
needs nothing: `build_merged_levels` already filters draft levels per mode, so
a ghost role contributes no columns in view mode.

- **Org-structure inline renames** — hover-pencil inline editors on the
  **role-family name** and **role name** in the left role tree
  (`RoleFamilyNameFrame` / `RoleNameFrame`, rendered by `RoleTree` when
  `mode == :edit`) and on each per-role **level title** in the matrix header
  (`LevelTitleFrame`, rendered by `MatrixHeader#full_title_badges`). These use
  the shared `InlineEditable` pencil/form helpers but — unlike capability /
  category text — are **direct edits, NOT the suggested-edit path**: org
  structure has no approval tier, so there is no pending decoration, no
  editing/suggesting toggle interaction, and no `SuggestionDecoration`. Each
  PATCHes a thin controller (`Frameworks::{RoleFamilies,Roles,Levels}Controller`)
  that dispatches `Operations::Frameworks::{UpdateRoleFamily,UpdateRole,UpdateLevel}`
  (shape-preserving → applies live, no draft) and re-renders the frame. Gated by
  `FrameworkPolicy#{update_role_family?,update_role?,update_level?}` (the
  `edit_structure?` bar). **Constraints:** the level-title pencil shows only when
  the header renders **full titles** (≤ 3 roles selected); the compact-code view
  (> 3 roles) stays read-only — titles are hidden there, so the user renames with
  fewer roles in scope. `MatrixDataBuilder#build_merged_levels` carries a
  per-role `level_id` in each `role_codes` entry so the editor targets one
  specific level. The inline pencils are **rename-only** — code / track / the
  entry flag are edited via the role-row kebab's dialogs (see §11).
- **Role-family edit dialog** — a hover "edit" trigger on each family row opens
  the shared `RoleFamilyEditModal` (name + description + **department**),
  *alongside* the inline name pencil (kept for quick renames). Gated on
  `can_edit_structure` (the `update_role_family?` bar). Department is a free-text
  grouping label with a `<datalist>` of the framework's existing departments —
  moving a family between groups is editing the string (no department entity).
  The submit dispatches the same `Operations::Frameworks::UpdateRoleFamily`
  (shape-preserving → live, no draft) but targets the **`role-tree-families`
  Turbo Frame**: the tree's family list (wrapped in that frame) re-renders so the
  family moves under its new — or a brand-new — department header, while the
  `tree` controller / track filter outside the frame stay put. The current role
  selection rides along as hidden `roles[]`/`track` inputs the
  `role-family-edit-form` controller fills from the URL, so checkboxes stay
  checked. `RoleFamiliesController#update` forwards only changed fields (so a move
  reads as "department" in the activity feed) and branches on the `Turbo-Frame`
  header — the families frame for the dialog, the per-family name frame for the
  inline rename.
- **Department-header rename (bulk relabel)** — each department group header is
  itself inline-editable in edit mode (`DepartmentNameFrame` + the shared
  inline-editor pencil). Saving relabels the department across **every** family
  in the group: `Frameworks::DepartmentsController#update` dispatches
  `Operations::Frameworks::RenameDepartment`, which fans out to
  `UpdateRoleFamily(department:)` per affected family (a blank target ungroups
  them all). It re-renders the same `role-tree-families` frame so the group
  re-labels in place; the `tree-scope-fields` controller injects the current
  role selection at submit (via the form's `formdata` event) so checkboxes stay
  checked. Both controllers share `Frameworks::RoleTreeFamiliesFrame` for the
  frame render. Gated by `#update_role_family?`. A bulk rename emits one
  `RoleFamilyUpdated` per family, so it shows as N department entries in the
  activity feed.

**Shared modals under one `modal` controller.** Archive(-capability),
add-capability, add-category, and archive-category are four embedded `Kit::Modal`s
on the explorer root, all driven by a single `modal` Stimulus controller. Each
trigger names its overlay via `data-modal-target-id="<overlay id>"`; the
controller opens that overlay (falling back to the lone overlay when a page has
only one — so the assessment evidence / delegation modals are unchanged). Feature
controllers prefill from the `modal:open` event's `dataset`: `add_capability_form`
(category id/name), `archive_form` (capability id/name, needs-mapping, hides self
from survivors), `mapping_form` (toggles the survivor select by mapping type),
`archive_category_form` (category id/name — no mapping).

These modals hold unsaved input (names, descriptions, migration mappings,
reject reasons), so outside-click dismissal is **off** — the explorer root's
`modal` controller leaves `dismissOnOutsideClick` at its default (false), so a
stray background click can't discard a half-filled structural form. They close
via the × button, Cancel, Esc, or a successful submit.

**Operations-first (web + MCP parity).** Add/archive/publish/mapping all dispatch
`Operations::Frameworks::*` (`AddCapability`, `AddCategory`, `ArchiveCapability`,
`ArchiveCategory`, `DefineMigrationMapping`, `PublishVersion`) so the web
controllers and the MCP tools share one implementation (the house rule).
`AddCategory` is shape-preserving (applies live).
`AddCapability`/`ArchiveCapability`/`ArchiveCategory` are shape-changing → they
**auto-open a draft** and the affected entity is **deferred from the published
read model until publish** (see Hard-Won Lesson 17). `ArchiveCategory` has no
migration mapping (categories carry no ratings) but the aggregate rejects it
while active capabilities remain — empty the category first.

### 12. Actionable feed entries (inline suggestion review) — the recurring pattern

The activity feed is not just a narrative log — a **pending suggestion's
submission entry is *actionable*** for a reviewer who can clear its tier. This is
the canonical instance of a reusable **"actionable feed entry"** pattern: an
entry that both narrates *and* offers the action inline, with a modal escape
hatch for the cases that need input. The same pattern applies to the assessment
feed (see [assessments.md](assessments.md)) and to future suggestion entity
types — they inherit it for free.

**Five invariants (apply the pattern, don't reinvent it):**

1. **Actionable iff `pending? && latest-proposal && viewer-has-authority`, computed server-side.**
   An unauthorised viewer never receives the controls (no client-side hiding). The
   feed query overlays each suggestion entry with `suggestion_status` +
   `suggestion_entity_type`; the controller computes a per-viewer
   `Frameworks::SuggestionApprovalAuthority` **once** (not a policy per entry) and
   threads it to the entry, which gates on `authority.can_approve?(entity_type)`.
   Tier routing has one source of truth: `FrameworkSuggestionPolicy.review_tier`
   (entity → tier) + `FrameworkState::Collaborator::CONTENT_APPROVE_ROLES`
   (tier → roles).
   **Amended suggestions: the action lives on the *latest* proposal.** A suggestion's
   feed entries are its original `suggestion_edit` plus one `suggestion_amended`
   per amendment — all sharing one `suggestion_id`. `ActivityFeedQuery#flag_superseded_proposals`
   walks the newest-first entries and flags every proposal but the most recent per
   `suggestion_id` as `superseded`; `Entry#actionable?` requires `!superseded`, so
   exactly one entry (the latest amendment, showing the up-to-date value) carries
   Approve/Reject — approving an out-of-date proposal is pointless. `suggestion_amended`
   is in `ACTIONABLE_KINDS` and `action_row` renders the same inline approve + modal
   reject as `suggestion_edit` (its proposed value is under `:new_suggested_value`).
   (One-pending-suggestion-per-author-per-field is enforced upstream by
   `Operations::Frameworks::SuggestEdit`'s amend-on-consecutive-edit routing;
   multi-author stacking on the same field is unchanged.)
2. **Primary action inline (one-click); Reject via a modal — for *every*
   actionable kind.** **Approve** is one click; **Reject** opens the shared reject
   modal for an **optional, surfaced** reason. This now covers create/delete
   proposals too, not just shape-preserving edits — a deletion proposal is as
   visible and one-click to action as an edit (approving it stages the
   add/archive into a draft; the publish step remains the `:in_app` gate, so it's
   still recoverable before the version is cut). Earlier, create/delete fell back
   to a muted detail-page "Review" link — easy to miss for the seed/MCP-created
   deletions that are reachable today; `Entry#action_row` keys on
   `suggestion_id.present?` and the else-branch `review_link` is now only a
   defensive fallback for a future actionable kind without an inline form.
3. **Every action dispatches an `Operations::*` class** (web + MCP parity). The
   four lifecycle ops are `:mcp_client`; the web's inline-vs-modal split is pure
   UX, decoupled from the MCP approval category.
4. **Resolution updates every affected frame and broadcasts live — with
   instant local feedback first, and a surgical grid update by default.**
   Because the broadcast round trip takes 1–2s in production, the actor never
   waits on it for feedback: the approve button reads "Approving…" during the
   POST and the entry's action row swaps in place to "✓ Approved" /
   "✓ Rejected" the moment the request succeeds (`suggestion-action`'s
   targets; the reject modal reaches the entry via the `suggestion:resolved`
   detail's `suggestionId` + `outcome`). The inline (`inline=1`) response is a
   **surgical Turbo Stream** replacing just the affected entity's frame
   (`Frameworks::SuggestionResolutionStreams` — illustration / expectation /
   capability / category edits, illustration creates+rejects); shapes it can't
   address (shape-changing creates/archives, org-structure) answer **204** and
   the client falls back to the full matrix refresh. Never widen the fallback
   casually: the full edit-mode matrix is several MB of HTML with thousands of
   Stimulus mounts, and re-fetching it per approval froze the tab (Hard-Won
   Lesson 23). The `suggestion:resolved` detail carries `surgical: true|false`
   so `matrix#refresh` knows whether to skip. The **feed** then reloads off
   the existing activity broadcast (`broadcast_framework_activity`,
   replay-guarded; the actor sees their own resolution) — **preserving the
   pane's scroll position** (the scroll container lives inside the reloaded
   frame, so `context-pane` captures and restores it; a reviewer working down
   a long feed is never thrown back to the top). Matrix updates are
   acting-user-only by design — feed-live / matrix-not (Hard-Won Lesson 21).
5. **No internal categorisations surfaced** — review tiers stay invisible (§9).

**Modal placement (load-bearing):** the reject modal lives on the **explorer
root**, not inside `#suggestion-panel` — a frame reload (which the feed does on
every resolution) would otherwise destroy an open modal. It shares the root
`modal` controller with the structural modals (Lesson 19); the `modal` controller
is therefore present for **all** edit-mode viewers, not just `can_edit_structure`
holders. `reject_suggestion_form` prefills it from the trigger dataset and points
the form at the suggestion's reject endpoint (a `__SID__` path template).

**Click-vs-navigate:** an entry row is itself a navigable button
(`context-pane#focusSuggestion`). The action controls must not also navigate, so
`focusSuggestion` bails when the event target is a `button`/`a` (mouse or
keyboard) — cheaper and more robust than `stopPropagation` (which would also kill
the `modal#open` listener that fires during bubbling).

**Multiple surfaces, one machinery.** The same pattern drives the grid-side
kebabs, all backed by the shared
`Views::Frameworks::Explorer::Concerns::ApprovalKebabItems` concern:

- **Matrix row-actions kebab** (`MatrixRow`, a `Kit::Dropdown`) — when a
  capability has a pending name / description edit the viewer can approve, the
  kebab gains **Approve / Reject «field» change** items (alongside
  **Archive…**, offered to any suggest-rights viewer — see §11).
- **Expectation cell kebab** (`MatrixCell`) — a hover-revealed ⋮ next to an
  expectation carrying a pending edit, for viewers who clear the expectation
  tier. Rendered OUTSIDE `ExpectationTextFrame` so the inline-edit frame swap
  can't drop it (no controller re-threading needed).
- **Illustration kebab** (`IllustrationFrame`) — same, inside the expanded
  row's hover control cluster, gated on the illustration tier. This one lives
  INSIDE the illustration's Turbo Frame, so `IllustrationsController#update`
  re-threads `approval_authority` on its frame response (Lesson 13/16 class),
  via the `Frameworks::SuggestionAuthority` controller concern.

They reuse the *exact* same pieces — `suggestion-action`
(inline approve, `inline=1` → surgical Turbo Stream, else 204), the root
reject modal, and `suggestion:resolved` → `matrix#refresh` — so approving
from the grid and from
the feed are the same operation with the same live-update wiring (the feed
reloads via broadcast either way). Pending **creates** (the ghost frames)
carry the same kebab — "Approve/Reject new illustration/expectation" — so a
proposed entity is as one-click to action from the grid as a proposed edit
(the squiggle click's card remains the discussion path; the ghost frame
re-renders — `IllustrationsController#render_pending_turbo_stream`,
`SuggestionsController#render_pending_ghost_frame` — re-thread the authority).
One deliberate boundary remains: a pending edit landed via an inline frame
swap gets its EXPECTATION kebab on the next matrix render, not immediately
(that kebab lives outside the swapped frame; the matrix deliberately isn't
live — Lesson 21 — and the squiggle→card path covers the interim). Kebab
composition follows the phlex-views.md rule: the kebab is the right-most
control and absorbs secondary actions — the illustration kebab also holds
Archive…, the role-tree kebab also holds Add level…. The per-viewer authority is threaded into the
matrix the same way `can_edit_structure` is: controller → `Matrix` →
`MatrixCategoryGroup` → `MatrixRow` → `MatrixCell` / `IllustrationFrame`.
`matrix#toggleRow` already ignores clicks inside
`[data-controller~='dropdown']`, so opening a kebab never expands the row.

### 12a. Suggestions are anchored discussions — the clarification kind

A **suggestion is an anchored, lifecycled discussion**, of which *proposals*
(edit / create / delete — the kinds applied on approval) are the applying
subset. This framing became explicit with the fourth kind, **`clarification`**
(born from calibration sessions — see
[calibration-sessions.md](../architecture/calibration-sessions.md)): a
discussion anchored on a capability × level cell that proposes nothing —
"what does this expectation actually mean?" — and may resolve into a
rewording, better illustrations, or "the text is fine, here's the reading".
Future features that need an anchored conversation with a lifecycle (e.g.
assessment-side open questions) should inherit this framing instead of
rediscovering it. Mechanics:

- **Domain**: `ClarificationRequested` → the same `framework_suggested_edits`
  table with `kind: "clarification"` and nil `field`/`suggested_value` (the
  presence validations were always proposal-kind rules). Anchor = the cell's
  expectation when one exists; else the capability with `level_ordinal` in
  `proposed_attributes`. The question itself is the `rationale`.
- **Lifecycle verbs differ — that is the whole delta.** No approve/reject/
  amend (the aggregate and `FrameworkSuggestionPolicy` both refuse): a
  clarification is **resolved with a required note** (`ClarificationResolved`,
  status `"resolved"`, note in `reviewer_comment`, optional
  `resulting_suggestion_id` linking the concrete change it spawned) or
  withdrawn by its author. Resolve authority is expectation-tier
  (`FrameworkSuggestionPolicy#resolve?` — whoever could change the text can
  declare the question settled).
- **Everything else is inherited untouched**: discussion threads, the feed +
  suggestion card rails, the suggestion index. Clarification entries
  (`clarification_requested` / `clarification_resolved`, suggestions chip)
  carry a **"Resolve…"** action for authorised viewers — the §12 pattern's
  needs-input variant (the note is required, so there is no one-click path;
  the root-mounted `resolve-clarification-modal` +
  `resolve_clarification_form` controller mirror the reject modal exactly).
- **Grid decoration is the content language, never the pending-change
  vocabulary**: an open clarification renders a muted **speech-bubble glyph**
  on the affected cell (the capability row when the anchor is the capability;
  the expanded row's example when it's an illustration) —
  `SuggestionDecoration#render_clarification_glyph`, edit mode only. It is
  deliberately NOT the wiggle: a clarification proposes no change, so
  `build_suggestions_map` routes it to a separate `clarification_count`
  (never `:count`/`latest_by_field`, so no wiggle, no diff, no "N pending"
  pill). Same glyph vocabulary as the assessment level chips.
  **The glyph is clickable** — it opens that discussion's card via the same
  `suggestion:open-card` path the squiggle uses, so the grid is a way *into*
  the conversation, not just a marker of one. `build_suggestions_map` keeps
  the latest open clarification's id per entity (`latest_clarification`)
  alongside the count, threaded by `MatrixDataBuilder` as
  `clarification_suggestion_id` (cell + capability) and
  `illustration_clarifications` (`{ count:, suggestion_id: }` per illustration).
  **The glyph must reach everything it counts.** The cell's count includes
  discussions on its *examples* (an illustration-anchored one is otherwise
  invisible on a collapsed row). The glyph opens the **most recent**, and the
  card lists its siblings — `SuggestionCardFrame#siblings_block`, fed by
  `ActivityController#sibling_discussions`, which reads the other open
  clarifications on the same cell (the expectation plus its illustrations)
  **straight from `FrameworkState::SuggestedEdit`**. Deliberately not via the
  activity feed: that is capped at the newest `STREAM_READ_LIMIT` events and
  can't page older while focused, so routing "show me the rest" through it
  would silently lose old discussions. Threading a lone id with no sibling list
  was a real reported dead end — a cell showing "2" that could only ever reach
  one.
- **Asking is a grid affordance — "Discuss…"** (edit mode). Three triggers,
  all plain `click->modal#open` buttons carrying a `discuss_*` dataset (no
  per-trigger Stimulus mount — one per cell is exactly the direction Lesson 23
  forbids), all opening the root-mounted `request-clarification-modal`:
  a hover-revealed **speech-bubble button on each expectation cell** (before
  the kebab, which stays right-most), a **"Discuss…" item in the capability
  row kebab** (no single cell in mind, so the modal offers that row's levels
  plus "the capability as a whole"), and a **"Discuss…" item in each
  illustration's kebab** (the case that prompted this: an example that reads
  wrong for its level). All are offered to **any edit-mode viewer** — edit mode
  already requires the suggest rights a clarification needs — so the row kebab
  is now unconditional in edit mode. `Concerns::DiscussTrigger` owns the
  markup; `request_clarification_form_controller` prefills the modal from the
  trigger dataset. POST → `Frameworks::ClarificationsController` → 204 +
  `X-Suggestion-Id`, and the form controller dispatches `suggestion:open-card`
  with that id, so the author lands in the discussion they just opened.
- **Anchors, most specific first**: an illustration when one is named (its
  level comes from the owning expectation), else the cell's expectation, else
  the capability — with `level_ordinal` when the question is cell-scoped and
  **without** it when it's about the capability as a whole.
- **Writers**: `frameworks_request_clarification` /
  `frameworks_resolve_clarification` (web + MCP, `:mcp_client`), plus the
  calibration flag (`Operations::CalibrationSessions::FlagExpectation` —
  authorized as the session facilitator, deliberately independent of
  framework collaborator roles).

### 13. Suggestion discussion threads

Every suggestion carries a **discussion thread** — the collaborative
conversation that informs the approve/reject decision. Threads live where the
decision is made: the pane's **suggestion card** (§8, `suggestion` focus) and
the detail page render the same `Views::Frameworks::Suggestions::Thread`.

- **Domain**: `SuggestionCommented` / `SuggestionCommentEdited` /
  `SuggestionCommentDeleted` on the framework stream →
  `Frameworks::Projections::SuggestionThread` →
  `FrameworkState::SuggestionComment` (PK = event-carried comment_id; soft
  delete keeps reply chains coherent). Threads **stay open after resolution**
  (the PR-conversation convention) — the aggregate never gates on pending.
- **Threading = the assessment comment model verbatim**: a reply may target ANY
  non-deleted comment on the same suggestion (unbounded depth in data);
  **display is chronological and flat with ONE indent level** — depth beyond
  one rides the "↳ replying to" chip, never deeper nesting. The DOM-generic
  `comments-thread` Stimulus controller is reused as-is (same target names,
  same `comment[...]` param namespace).
- **Authorization**: posting sits on the suggest bar
  (`FrameworkPolicy#comment_on_suggestion?`); edits are author-only, deletes
  author or tenant admin (`FrameworkSuggestionCommentPolicy`, mirroring
  `PersonDevelopmentCommentPolicy` — both bars also enforced in the
  aggregate/ops).
- **Operations-first (web + MCP)**: the web endpoints
  (`Frameworks::SuggestionCommentsController`) and the MCP tools share
  `Operations::Frameworks::{CommentOnSuggestion,EditSuggestionComment,
  DeleteSuggestionComment}` (`:mcp_client`), and `frameworks_suggestion_get`
  (`:none`) returns the full suggestion + nested thread — the read drill-in
  from a feed entry's suggestion_id.
- **Feed**: posts surface as `suggestion_commented` entries (suggestions chip);
  edits/deletes are thread-only. Every suggestion-anchored entry renders the
  **discussion affordance** — comment count + latest excerpt (or "Discuss") —
  fed by `ActivityFeedQuery`'s one-pass `comment_stats` overlay; clicking it
  opens the suggestion card.
- **Shareable by link**: the card carries a **permalink glyph** (the
  conventional link icon, so it needs no label and leaves the title its width)
  handing over
  an absolute deep link (`/frameworks/:id/edit?focus=suggestion&suggestion_id=…`)
  — the explorer URL, not the standalone suggestion page, so the recipient lands
  on the discussion *with the grid around it*. Built in
  `Frameworks::ActivityController#discussion_permalink` from `request.base_url`
  (whichever host the sharer is on, not a configured canonical) and copied via
  the shared `clipboard` controller — via its `idle`/`copied` glyph-swap
  targets, since the default feedback rewrites `textContent` and would erase
  an inline SVG. **This is currently the only way a question
  reaches a specific person** — there are no notifications for framework events
  and no @-mentions in threads, so sharing the link IS the delivery mechanism;
  treat it as load-bearing, and note both surfaces sit behind the suggest bar
  (`framework_collaborator_can_suggest?`), so a viewer-role recipient is bounced.
- **Draft protection (NON-NEGOTIABLE)**: broadcast reloads of the pane are
  **suppressed while any composer textarea is focused or holds text**
  (`context_pane_controller#composerDirty`) — the same failure class that
  forced the reject modal to be root-mounted (Lesson 19) would otherwise eat
  half-written comments on every framework-wide broadcast.

### 7. Responsive Behaviour

| Viewport | Role Tree | Matrix | Toggle Button |
|----------|-----------|--------|---------------|
| Desktop (≥ 1024px) | Inline left pane | Adjacent to tree | Visible, toggles inline |
| Mobile (< 1024px) | Hidden, fixed overlay on toggle | Full width | Visible, opens overlay |

The toggle button is the **role count stat** in the header ("4 Roles" with a chevron). It serves double duty: displaying information and providing the toggle affordance.

Mobile overlay closes on click-outside via `useClickOutside` from stimulus-use.

## Sticky Positioning

The matrix uses a precise z-index hierarchy for sticky elements:

| Element | Position | z-index | Purpose |
|---------|----------|---------|---------|
| Corner cell ("Capability") | `sticky top-0 left-0` | `z-20` | Always visible at intersection |
| Column headers (levels) | `sticky top-0` | `z-10` | Visible when scrolling vertically |
| Category headers | `sticky top-[41px]` | `z-[5]` | Below column headers, above data |
| Left column (capability name) | `sticky left-0` | `z-[2]` | Visible when scrolling horizontally |

**Every sticky cell must be OPAQUE in both themes (NON-NEGOTIABLE).** A sticky cell is a mask — content scrolls underneath it — so a translucent background (`bg-…/NN`) or a missing one lets that content render straight through. This applies to hover and focus variants too, not just the base class. Where the design wants a tint, use the **opaque composite** (the literal hex of that tint over the surface behind it) rather than the translucent token, so the cell looks identical but actually masks; derive it by compositing in the browser, not by eye, and record the token + surface at the call site. The shared right-edge treatment and the full rationale live in [`concerns/sticky_column.rb`](../../app/views/frameworks/explorer/concerns/sticky_column.rb) — see Hard-Won Lesson 24.

| Sticky cell | Light | Dark |
|---|---|---|
| Header corner + level columns | `bg-gray-50` | `dark:bg-gray-900` |
| Compact row (capability name) | `bg-white`, hover `bg-gray-50` | `dark:bg-gray-900`, hover `dark:bg-[#172131]` (= `gray-800/50` over `gray-900`) |
| Expanded row (empty gutter) | `bg-[#fafcff]` (= `blue-50/30` over white) | `dark:bg-[#111b31]` (= `blue-900/10` over `gray-900`) |
| Category header row | `bg-gray-100` | `dark:bg-gray-800` |

**Single scroll container.** The only scroll container is `main_pane` in `show_view.rb` (`flex-1 overflow-auto`, tagged `data-matrix-target="scrollContainer"`). The `<table>` must be rendered as a direct child of the turbo-frame inside it — do NOT wrap it in `overflow-x-auto` (or any `overflow-*`) divs. CSS `position: sticky` anchors to the nearest scrolling ancestor, so a nested overflow wrapper silently captures the anchor and breaks vertical stickiness (see Hard-Won Lesson 11).

## Stimulus Controller Responsibilities

### framework_explorer_controller.js
- **Role pane toggle** (desktop: inline show/hide, mobile: fixed overlay)
- **Click-outside close** on mobile (via `useClickOutside`)
- **Role count update** when tree selection changes
- **Toggle affordance** (chevron rotation, active state styling)

### tree_controller.js
- **Checkbox management** (role toggle, family bulk toggle, indeterminate state)
- **Solo mode** (save/restore selection state)
- **Track filter** (IC / Management / Both — hides roles, updates family state)
- **Event dispatch** (`tree:changed` with `{roleIds, track}`, bubbles to parent)

### framework_search_controller.js
Lives on the stats-bar search box. Debounces keystrokes (250ms, `useDebounce`)
and dispatches the window-scoped `framework-search:changed` event with the
trimmed query; Esc and the inline × clear immediately. Toggles the × affordance
on input. Does NOT touch the matrix or URL itself — that's `matrix_controller`'s
job via `updateSearch`. See §4a.

### matrix_controller.js
- **Turbo Frame update** (builds URL from selection, sets frame src)
- **Text-filter update** (`updateSearch` on `framework-search:changed`) — merges
  the query with the role/track scope read back from the browser URL, via the
  shared `#rebuildMatrixFrame`. See §4a.
- **Category collapse** (sibling row walking — triggered by chevron button only; the category name runs `focusCategory`)
- **Row expansion** (toggle hidden expanded row by capability ID). Dispatches `matrix:focus-changed` with `level: "capability"` on expand, `level: "framework"` on collapse.
- **Cell focus** (`focusCell` on expanded-row `<td>`) — dispatches `matrix:focus-changed` with `level: "cell"`. Ignores clicks that land on interactive children (buttons, links, inputs, forms, `[contenteditable]`) so inline editors inside the cell don't accidentally toggle focus.
- **Category focus** (`focusCategory` on the category name span). Dispatches `matrix:focus-changed` with `level: "category"`. Re-click clears to framework focus.
- **Panel navigation** (`navigateToEntity` on `suggestion:navigate` from context pane) — programmatically expands a row by capability ID, scrolls it into view, and dispatches `matrix:focus-changed`. For category-level navigation, scrolls to the category header. When the entry names a **pending suggestion**, scrolls to that suggestion's decorated element (`[data-suggestion-id]` anchor) and pulses `.suggestion-nav-highlight` on it — an expanded cell can be taller than the viewport, so cell-centering alone leaves the example off-screen; the cell/row scroll is the anchor-less fallback (the cell gets the same pulse).
- **Resolution refresh** (`refresh` on `suggestion:resolved`) — re-fetches the matrix frame with the current filter axes so an inline approve/reject in the feed clears the now-resolved inline diff for the acting user (§12, Hard-Won Lesson 21).
- **Squiggle → suggestion card** (`openSuggestionCard` on a decorated pending change) — stops the row/cell click and dispatches the window `suggestion:open-card` event; the context pane renders the card and a collapsed pane reveals itself (§10).
- **URL sync** (pushState for shareability — explorer uses role/track params)
- **Assessment URL sync** (gated behind `urlSyncValue`) — syncs `?category=` and `?capability=` to browser URL, dims sibling rows on expansion. Only active in assessment views; explorer DOM never sets this value.
- **Shared** between explorer and assessment views — same collapse/expand logic applies

### context_pane_controller.js (edit mode only)
Lives on the right-hand `<aside>` element. Sole owner of:
- **Panel frame src** (`#suggestion-panel`). Rebuilds the frame URL whenever focus, role selection, or a fresh suggestion submission occurs. Short-circuits when the computed URL equals the current `src` to prevent duplicate fetches. Forces a reload on `onSuggestionSubmitted` so a just-landed pending row surfaces even if the URL didn't change.
- **Focus portion of the browser URL**. Pushes `?focus=`, `?category_id=`, `?capability_id=`, `?level_ordinal=`, `?suggestion_id=` via `history.pushState()`; removes them when focus returns to `framework`.
- **Suggestion focus** (`openSuggestionCard`, from an entry's discussion affordance; `onOpenSuggestionCard`, from a matrix squiggle's window-scoped `suggestion:open-card`). Sets `focus=suggestion&suggestion_id=` so the frame renders the suggestion card instead of the feed. Any explicit matrix focus action (`matrix:focus-changed`) exits it — most-specific-wins, like every other level.
- **Initial hydration**. Reads focus params from the browser URL on connect so deep-link reloads render the filtered panel on first frame fetch. Unconditionally primes the frame `src` on connect because the pane is visible from initial render in edit mode (no lazy-until-open grace period — see Hard-Won Lesson 14).
- **Live reload**. Observes the hidden `#framework-activity-sync-signal` element (a `signal` target). `PublishedState#broadcast_framework_activity` (and `SuggestionThread`'s equivalent for comment events) replaces it on every feed-relevant event via the per-framework `framework_activity` Turbo stream; the observer reloads the feed frame with no self-suppression (the feed frame is the only thing that re-fetches, so there's no matrix flicker, and the actor should see their own entry) — but **coalesces signal bursts into one reload** (~300ms debounce — one approval publishes the approval AND the applied change, each nudging the signal; Hard-Won Lesson 23), **skips the reload while a composer textarea is focused or holds text** so a broadcast can't eat a half-written comment (§13), and **preserves the feed's scroll position across the reload** (the `overflow-y-auto` scroller lives inside the frame — a `scroller` target whose scrollTop is captured before every same-content reload and restored on `turbo:frame-load`; focus-driven `src` changes render different content and deliberately start at the top). Mirrors `assessment_sync_controller`.

Listens at window scope for:
- `tree:changed@window->context-pane#onTreeChanged`
- `matrix:focus-changed@window->context-pane#onFocusChanged`
- `suggestion:submitted@window->context-pane#onSuggestionSubmitted`
- `suggestion:open-card@window->context-pane#onOpenSuggestionCard`

Also dispatches:
- **`suggestion:navigate`** — fired by `focusSuggestion` when the user clicks a suggestion row body. Reads `data-nav-*` attributes from the clicked element and dispatches to window for `matrix_controller` to handle.

### inline_editor_controller.js
Wraps every inline-edit site (IllustrationFrame, PendingIllustrationFrame, NewIllustrationFrame, CapabilityNameFrame, CapabilityDescriptionFrame, CategoryNameFrame, CategoryDescriptionFrame, ExpectationTextFrame).
- **Display / form toggle** — `startEdit` hides the display target and reveals the form; `cancel` restores display and resets the textarea to its `defaultValue` (the server-rendered value, which is the **pending proposal** when one exists — see §10).
- **Post-submit signal** — on `turbo:submit-end` (bound via `data-action="turbo:submit-end->inline-editor#submitted"` on each form), dispatches a window-scoped `suggestion:submitted` event if the submission succeeded. `context_pane_controller` listens for it and reloads the suggestions panel so a just-landed pending row appears without a page refresh.

### edit_mode_toggle_controller.js (edit mode only)
Segmented Editing / Suggesting toggle in the header. Reads and writes the `framework_edit_mode` cookie (values `editing` | `suggesting`, 1-year max-age, SameSite=Lax). No server round-trip on select — the cookie is picked up on the next inline-edit form submission by the `FrameworkEditMode` controller concern. Takes caller-supplied `activeClass` / `inactiveClass` values so styling stays in the view, and flips `aria-pressed` on each segment.

### binding_editor_form_controller.js (edit mode only)
Companion to the `modal` controller for the shared binding-editor modal. On the
window `modal:open` event it self-gates on `bindingEditorCapabilityId` and points
the `binding-editor` Turbo Frame at {Frameworks::CapabilityBindingsController#index}
for that capability (with a cache-buster so reopening the same capability refetches
the latest state). All add/remove/weight actions then re-render the frame in place.

### frame_error_controller.js (edit mode only, in the explorer)
Shared with the assessment surfaces — the machinery is documented once in
[assessments.md](assessments.md)'s Stimulus-controller table, where it was
extracted from the evidence modal. In the explorer it rides the **binding-editor
and level-editor modal bodies**: a failed frame GET would otherwise render
Turbo's own "Content missing" into the multi-megabyte edit-mode explorer with no
retry, or leave "Loading…" standing forever (audit issue #365). Mounting is a
bare `data-controller="frame-error"` plus the `frame` / `error` targets — the
five listeners bind themselves in `connect()`, so a new surface cannot half-wire
them. Two rules matter when extending it here: it speaks **only for the frame's
own GET** — a failed in-frame row save (a weight PATCH, a level rename) keeps its
form and its typed values, because `turbo:frame-missing` is claimed only while a
load armed it — and the error copy is built from `subject:` + `closeable:` by
`Kit::FrameLoadError`, never passed in as free text.

### suggestion_action_controller.js (edit mode only)
Wraps the action row on an actionable feed entry (and mounts bare on the grid kebabs' Approve items). `approve` POSTs to the suggestion's approve endpoint (`inline=1`) via `@rails/request.js`, showing "Approving…" during the round trip and swapping the row to a local "✓ Approved" state on success — instant feedback, ~1-2s ahead of the broadcast-driven feed reload. The response is either a surgical Turbo Stream (request.js renders it — the affected entity's frame swaps in place) or a 204 fallback. Dispatches the window `suggestion:resolved` event with `{ suggestionId, outcome, surgical }` (→ `matrix#refresh` for the non-surgical fallback only, and → other surfaces showing the same suggestion resolving in place via `onResolved` — a bare kebab mount outside the swapped frame marks itself terminal); the reject modal's dispatch carries the same detail so a rejection swaps the entry to "✓ Rejected" too. Reject is *not* handled here — it always opens the shared modal (§12).

### request_clarification_form_controller.js (edit mode only)
Backs the shared "Start a discussion" modal (§12a). On `modal:open` it self-gates on a `discuss*` dataset key, copies the anchor (capability / illustration / level) into the form's hidden fields, fills the context line, and — when the trigger supplies `discussLevelOptions` (the capability row, which names no cell) — populates and reveals the level select. On a successful submit it reads the new suggestion id from the response's `X-Suggestion-Id` header and dispatches `suggestion:open-card`, so the author lands on the discussion they just opened; with no id it falls back to `suggestion:submitted` so the feed still refreshes.

### reject_suggestion_form_controller.js (edit mode only)
Backs the shared reject-suggestion modal. On `modal:open` it self-gates on `rejectSuggestionId`, points the form at that suggestion's reject endpoint (a `__SID__` path template), fills the entity label + proposed-value preview, and clears the reason. On a successful submit it dispatches `suggestion:resolved`. The modal closes via `modal#submitted`; the feed reloads via broadcast (§12).

### Event contracts

| Event | Source | Detail |
|-------|--------|--------|
| `tree:changed` | `tree_controller` | `{ roleIds: string[], track: "ic" \| "management" \| "both" }` |
| `framework-search:changed` | `framework_search_controller` | `{ query: string }` — trimmed text filter; triggers `matrix_controller#updateSearch` (window-scoped, since the search box sits outside the matrix element). See §4a. |
| `matrix:focus-changed` | `matrix_controller` | `{ level: "framework" \| "category" \| "capability" \| "cell", categoryId: string \| null, capabilityId: string \| null, levelOrdinal: number \| null, expectationId: string \| null }` — always fully specified |
| `suggestion:navigate` | `context_pane_controller` | `{ level: "category" \| "capability" \| "cell", categoryId: string \| null, capabilityId: string \| null, levelOrdinal: number \| null, suggestionId: string \| null }` — triggers `matrix_controller#navigateToEntity`. `suggestionId` (pending suggestions only) makes navigation land on the exact decorated element — the squiggle/ghost's `[data-suggestion-id]` inside the matrix frame — with a brief `.suggestion-nav-highlight` pulse; without an anchor (resolved, or the suggestion's role filtered out) it falls back to centering the cell (which gets the same pulse) or row. |
| `suggestion:submitted` | `inline_editor_controller` | `{ formAction: string }` — fired on successful `turbo:submit-end`. Triggers `context_pane_controller#onSuggestionSubmitted`, which forces the panel frame to reload so a just-landed pending row appears without a page refresh. |
| `suggestion:open-card` | `matrix_controller#openSuggestionCard` (squiggle / ghost click) | `{ suggestionId: string }` — opens that suggestion's card in the pane (`context_pane_controller#onOpenSuggestionCard`) and reveals a collapsed pane (`framework_explorer_controller#openContextPane`). The click's purpose IS to see the card, so this is the one deliberate exception to "focus never auto-opens the pane" (Lesson 8 still governs plain focus changes). |
| `suggestion:resolved` | `suggestion_action_controller` (approve) / `reject_suggestion_form_controller` (reject) | `{ suggestionId: string, outcome: "approved" \| "rejected", surgical: boolean }` — fired on a successful inline approve/reject (the clarification-resolve dispatch carries no detail; consumers must tolerate its absence). `surgical: true` means the response's Turbo Stream already replaced the affected frame — `matrix_controller#refresh` skips the full re-fetch and only runs as the fallback for non-surgical shapes (Hard-Won Lesson 23). The feed reloads separately via the activity broadcast (§12, Hard-Won Lesson 21). |

## Hard-Won Lessons

### 1. Checkbox action binding requires explicit event type

Stimulus defaults for `<input>` are `input` events. For checkboxes, use `change->tree#toggleRole` explicitly. Without the `change->` prefix, the action may not fire reliably across browsers.

### 2. Don't use `.closest('.hidden')` for visibility checks

The role tree aside has `max-lg:hidden` in its class list. A naive `checkbox.closest('.hidden')` matches the aside itself, making ALL checkboxes appear "hidden" even on desktop. Instead, check the **role div** specifically: `cb.closest("[data-tree-target='role']").classList.contains("hidden")`.

### 3. Mobile overlay requires inline styles, not class toggling

Tailwind's `max-lg:hidden` can't be overridden by adding/removing other utility classes at the same breakpoint — specificity is equal and the later rule wins unpredictably. Use `Object.assign(element.style, {...})` for the overlay and `element.removeAttribute("style")` to restore responsive behaviour.

### 4. Controller element scope matters for actions

A `data-action="controller#method"` on an element only works if a matching `data-controller` exists on that element or an ancestor. The "Roles" toggle button must be inside the `framework-explorer` controller's element — not a sibling.

### 5. Filter illustrations by selected roles in the builder

If the `MatrixDataBuilder` doesn't filter `illustrations_by_role` by `selected_role_id_set`, expanded cells show illustrations for ALL roles — even those not selected. This breaks the mental model that "I selected one role, I should only see that role's examples."

### 6. Turbo Frame must be re-fetched on selection change

The matrix is server-rendered. When roles change, the client must update the Turbo Frame `src` to trigger a fresh fetch. Client-side DOM manipulation alone can't replicate the server-side filtering logic (merged levels, capability bindings, illustration filtering).

### 7. Category row sibling walking

Finding all rows belonging to a category requires walking DOM siblings from the category header `<tr>` until hitting the next category header. CSS selectors alone can't express "all siblings between two markers."

### 8. Focus pane visibility and URL state are separate concerns

It's tempting to auto-open the context pane when the user takes a focus action (click a category name, click a cell). Don't. The URL always encodes the current focus so deep links work, but the pane itself only opens via the explicit toggle. Conflating visibility with focus causes surprise UI pops: users who closed the pane don't want it reopening every time they expand a row. Keep focus an invisible background state until the user explicitly asks to see it.

### 9. Stimulus `this.dispatch(...)` doesn't accept a `target:` option

To dispatch a window-scoped custom event from a controller, use native `window.dispatchEvent(new CustomEvent("prefix:name", { detail }))` rather than `this.dispatch(...)`. The built-in helper only dispatches on the controller's element; event listeners bound via `data-action="prefix:name@window->..."` never see controller-scoped dispatches.

### 10. JavaScript ASI bites array literals on new lines

This silently did the wrong thing:

```js
const url = new URL(window.location.href)
["focus", "category_id"].forEach(k => url.searchParams.delete(k))
```

Without a semicolon after the first line, JavaScript parses `new URL(...)["focus", ...]` as a subscript access and the `.forEach` never runs. The panel content narrowed correctly because `#rebuildFrameSrc` writes the frame `src` directly, but the browser URL was never pushed and the deep-link test failed. Either terminate with semicolons or extract the array into a named constant.

### 11. Nested `overflow-*` wrappers break sticky headers

CSS `position: sticky` anchors to the nearest scrolling ancestor. If the matrix `<table>` is wrapped in an inner `overflow-x-auto` (or any `overflow-*`) div, that wrapper captures the sticky anchor — even when the outer pane is the real scroll container. Headers then ride the tbody instead of pinning to the top of the pane, despite having `sticky top-0` declared. The table must be a direct child of the pane that scrolls it; the pane's own `overflow-auto` handles both axes.

### 12. Tailwind JIT can't see interpolated class names

Tailwind v4 scans Ruby source files for class literals at compile time. A class built by interpolation — e.g. `"group-hover/#{token}:opacity-100"` — is invisible to the scanner. The final string lands on the DOM element, but no matching CSS rule is ever generated, so a hover-revealed pencil button stays permanently at `opacity-0`. Any token used inside a Tailwind utility (group names, variant suffixes, arbitrary values) must appear as a literal string somewhere in source, not be assembled at runtime.

### 13. Controller responses that re-render an editable component must pass `mode: :edit`

When an inline-edit controller (e.g. `IllustrationsController`, `CapabilitiesController`) responds with a re-rendered turbo-frame, the component's `mode:` kwarg must be explicitly set to `:edit` — otherwise it falls back to the default `:view` and the response drops the pencil affordance, the hover-revealed form, and the `data-controller="inline-editor"` attribute. The user can edit once successfully; the second edit is impossible because the affordance is gone. Every edit endpoint needs `mode: :edit` in its response render call.

### 14. A visible Turbo Frame with `src:` auto-fetches before Stimulus primes

With the context pane hidden by default, `loading: "lazy"` meant the frame only fetched on first open — by which time `context_pane_controller` had run `connect()` and set the focused `src`. Making the pane visible by default in edit mode broke that: the lazy fetch fires on initial layout, using the un-focused server-rendered `src`, before the controller rebuilds for deep-link focus params. Fix: omit the `src:` from the server-rendered frame and let the controller unconditionally set it on connect.

### 15. Aggregate on-handlers and event data keys drift silently until the aggregate becomes a read source

`Frameworks::Aggregate` emits `RoleIllustrationUpdated` and `BehaviouralExpectationUpdated` with `new_description:` in the event payload (both from `update_role_illustration` / `update_behavioural_expectation` and from `apply_suggested_content_change` after an approved suggestion). The aggregate's `on` handlers, however, were reading `event.data[:description]` — which is nil — so the in-memory ivars never updated. This was invisible for years because the aggregate was only a write-side validator; the PublishedState projection read `event.data[:new_description]` correctly and kept the AR read model in sync.

The moment the aggregate became the source for `ExplorerGraph` (see the snapshot-on-write path in `Repository#with_framework`), the bug surfaced as "missing content": after an auto-approved inline edit, the graph snapshot captured the pre-edit text from the stale aggregate ivar, and subsequent page loads served the old value. Fix was a one-line change per handler to read `:new_description` (with `:description` as a defensive fallback). Lesson: whenever an aggregate handler's behaviour starts mattering beyond command validation — anywhere a reader consumes the aggregate's in-memory state — audit the handlers against the event payload keys.

### 16. Controller responses that swap an entity frame must re-query the pending count

After a submit lands, the inline-edit controllers (`Illustrations`, `Capabilities`, `Categories`, `Expectations`) render a fresh turbo-frame containing the post-edit entity. If they pass `pending_edit_count: 0` (or omit it), the wavy-underline decoration doesn't appear — even though a pending suggestion just got created in Suggesting mode. Each response must re-query `FrameworkState::SuggestedEdit.pending` for the entity and thread the count into the frame constructor, so the user sees the pending decoration land immediately without a reload. The `MatrixDataBuilder` path would pick this up on the next full render, but for the in-place Turbo swap the controller has to do it itself.

### 17. Inline-editing / archiving a draft-added capability must resolve from the graph, not the read model

`add_capability` is **shape-changing**, so a capability added in the current
draft is **deferred from the published `FrameworkState::Capability` read model**
until publish — but it renders in the edit-mode matrix (sourced from the
`ExplorerGraph`). The inline-edit (`CapabilitiesController#set_capability`) and
archive (`Operations::Frameworks::ArchiveCapability#capability`,
`CapabilityArchivesController#set_capability`) paths originally looked the
capability up in the AR read model → `404` / silent dead-end on a freshly-added
capability you could see on screen. Fix: resolve from the `ExplorerGraph`
(`graph.capability_categories.flat_map(&:capabilities).find { … }`), which
includes draft-added entities. The graph is per-framework, so finding the id in
it also scopes the lookup to the authorized framework. After an auto-approved
edit, re-resolve from a **fresh** graph load (the snapshot was rewritten).
Categories don't have this problem — `add_capability_category` is
shape-preserving (applies live), so a new category is in the read model at once.

### 18. Empty categories must stay visible in edit mode

`MatrixDataBuilder#build_categories` drops categories with no visible
capabilities (`next if capabilities.empty?`) — correct for the clean view mode,
but it made a freshly-added (still empty) category **vanish**, with no way to add
capabilities to it. Keep empty categories **in edit mode** (still dropped in view
mode and while searching): `next if capabilities.empty? && (@mode != :edit ||
searching?)`.

### 19. Multiple modals under one `modal` controller need `data-modal-target-id`

The shared `modal` Stimulus controller originally assumed one overlay per
controller-ancestor. The explorer now hosts four (archive-capability /
add-capability / add-category / archive-category) plus the reject-suggestion
modal, and their triggers all live inside the same matrix — you can't nest a
second `modal` controller (the inner one wins for everything beneath it).
So `modal#open` resolves the overlay by the trigger's `data-modal-target-id`,
falling back to the single `overlayTarget` when none is set. The fallback is
load-bearing: it keeps existing single-modal callers (assessment evidence /
delegation) working unchanged — but once >1 overlay shares a controller, **every**
trigger must name its overlay or it opens the wrong (first) one.

### 20. One endpoint, two surfaces — branch on an explicit marker, not request format

`SuggestionsController#approve`/`reject` serve both the suggestion **detail page**
(wants a redirect + flash) and the **inline feed/grid** (wants a quiet no-op). The
first instinct — `respond_to` on `format.html` vs `format.turbo_stream` — is
**wrong**: the detail-page forms are Turbo-driven (they carry `data-turbo-confirm`),
so they submit with the same `Accept: text/vnd.turbo-stream.html` as the inline
surfaces. Branching on format routed the detail page into the inline (`head :ok`)
arm and it silently stopped redirecting. Fix: the inline surfaces flag themselves
with an explicit `inline=1` param; everything else (incl. the Turbo detail page)
redirects. The lesson generalises: when two callers of one action want different
responses but can't be told apart by format, pass an explicit intent marker.
The same marker now covers `#amend`: the pending-illustration ghost's amend
form lives inside its `pending-suggestion-<sid>` Turbo Frame, so the
detail-page redirect rendered "Content missing" — with `inline=1` the action
re-renders the ghost frame in place (errors included: a bodyless 4xx would
blank the frame the same way, so failures re-render the frame with the
message surfaced).

### 21. Inline resolution answers a Turbo Stream or 204 — never a bare 200

Two halves of the "actionable feed entry" wiring that are easy to get wrong:

- **A stream or a 204, never an empty 200.** A Turbo form submit (the reject
  modal) that gets a `200` with an empty body makes Turbo Drive render the
  empty body — **blanking the page**. The inline resolution response is either
  a turbo-stream (processed in place, no navigation) or `head :no_content`
  (Turbo does nothing: the modal closes via `turbo:submit-end` and the page is
  untouched). (The approve path uses `@rails/request.js`, which doesn't
  navigate regardless.)
- **Feed-live, matrix-not.** The feed reloads for everyone via the activity
  broadcast, but the matrix deliberately does **not** live-reload (it would flicker
  / reset scroll for other viewers mid-edit). So an inline approve must update the
  **acting user's** matrix itself — the surgical stream in the response, or, for
  non-surgical shapes, a window `suggestion:resolved` → `matrix#refresh`
  (re-fetch with the current `roles[]`/`track`/`q` axes; skipped when
  `detail.surgical` — Lesson 23). Other viewers pick up the applied edit on
  their next interaction. Symmetric: a grid-side approve refreshes the feed the
  same way (via the broadcast).

### 22. The pane's scroll container lives INSIDE the reloaded frame — reloads must preserve it, and feedback must not wait for them

Two coupled consequences of the pane's broadcast-reload design, found via field
feedback ("Approve is super slow… it then takes me to the top"):

- **Scroll**: the feed/card `overflow-y-auto` scroller is part of the frame
  content, so every `frame.reload()` replaces it and resets `scrollTop` to 0 —
  a reviewer working down a long list of pending suggestions was thrown to the
  top after each approval. `context-pane#reloadPreservingScroll` captures
  **which entry** the reviewer is on (topmost visible `li` + its offset)
  before every **same-content** reload (broadcast, post-submit, catch-up) and
  scrolls back to that entry on `turbo:frame-load` — entry-anchored, because a
  pixel offset drifts one entry per action (the resolution being reloaded
  prepends 2+ fresh entries above the reviewer's position, compounding over a
  session). The pixel position is the fallback when the anchor entry isn't in
  the fresh content (it lived in a discarded "load older" batch), still
  exact-or-nothing. Focus-driven `src` changes render *different* content and
  start at the top — with one deliberate exception: **leaving the full feed
  for a review detour** (entry click-through narrows the feed; opening a
  suggestion card swaps it) remembers the departure entry, and returning to
  framework focus (the "Show all" link, collapsing the row) restores it — the
  click-through → verify → act → return loop is exactly how a reviewer works
  down a long list, and it used to dump them at the top on every return.
- **Feedback**: the actor's entry only visibly changed when the broadcast
  round trip re-rendered the feed (1–2s in production) — long enough that
  users re-clicked, thinking the first click hadn't registered. Resolution
  feedback is therefore **local first**: "Approving…" during the POST, the
  action row swaps to "✓ Approved"/"✓ Rejected" on success (via the
  `suggestion:resolved` detail — one code path for self, the reject modal,
  and other surfaces), and the broadcast reload merely converges to the
  canonical state. Never make perceived responsiveness wait on a broadcast.

Known trade-off: a reload discards "load older" batches. When the anchor
entry itself came from a discarded batch, the pixel fallback is
exact-or-nothing — a saved position deeper than the fresh (first-batch)
content starts at the top of the visibly-reset list rather than landing at
the bottom of an unrelated stretch of feed.

Two Turbo timing facts the restore machinery relies on (verified against the
Turbo JavaScript source bundled by turbo-rails 2.0.23, not assumed):

- **A frame's `busy` attribute is set a microtask AFTER a navigation starts,
  and a successful load dispatches `turbo:frame-load` BEFORE `busy` clears**
  (`requestFinished` runs after the awaited `loadResponse` that fires the
  event; a failed or frame-missing response clears `busy` without any
  `turbo:frame-load`). So `busy` is blind in the same task as a `src`
  assignment and still present during the frame-load handler — any decision
  hung on it must be deferred past a macrotask, never read inline.
- **A pass measuring the DOM across rAF retries can outlive its content.**
  The narrowed feed renders the same `li` ids as the full feed, so a retry
  queued against the old content can false-match a newer anchor. The
  controller guards this with a restore-generation counter (bumped per load
  and per anchor install); clears within the current pass deliberately do
  NOT bump it, or they'd mark their own retry stale.

### 23. Never re-fetch the whole matrix per approval — the edit-mode frame is megabytes

Field report ("a few times I have had an error — quit or wait for growthOS to
respond"): every inline approve/reject dispatched `suggestion:resolved` →
`matrix#refresh`, a full re-fetch of the edit-mode matrix frame. On the real
me&u framework that frame measures **~6.7 MB of HTML with ~3,300 Stimulus
controller mounts, ~3,200 forms and ~2,400 textareas** (every cell pre-renders
its hidden inline-edit form) — each swap costs seconds of main-thread parse +
controller teardown/connect, and consecutive approvals overlap into Chrome's
page-unresponsive dialog. Two rules fell out:

- **Resolutions update surgically.** The approve/reject response replaces just
  the affected entity's Turbo Frame (`Frameworks::SuggestionResolutionStreams`);
  the full refresh survives only as the fallback for shapes with off-frame
  side-effects (draft pill, row strikethrough). A stale approval kebab that
  lives OUTSIDE the swapped frame (row/cell kebabs) is marked terminal
  client-side — `render_approval_kebab_items` wraps its items in a
  `suggestion-action` mount listening for `suggestion:resolved`, and
  `onResolved` relabels + disables them — rather than re-rendered. Accepted
  staleness boundary (same class as the "kebab appears on next render" rule in
  §12): passive off-frame counters — the ≥2 "N pending" pill and the compact
  cell's "N examples" badge — keep their pre-resolution values for the acting
  user until the next matrix render. They're informational, converge on any
  interaction, and the alternative is re-fetching megabytes per approval.
- **Broadcast bursts coalesce.** One approval publishes multiple feed-relevant
  events (the approval + the applied change), each nudging the sync signal —
  `context-pane` debounces the signal into a single feed reload (~300ms)
  instead of re-fetching the 300KB+ feed once per event.

The deeper fix (rendering the inline-edit forms lazily so the matrix frame
itself shrinks) is tracked separately; until then, treat "re-fetch the matrix"
as a last resort in any new explorer feature.

### 24. A translucent background on a sticky cell is a hole, not a tint

`position: sticky` does not clip what passes under it — the cell's own
background is the only thing masking the scrolled content. So a sticky cell
with `bg-blue-50/30 dark:bg-blue-900/10` (the expanded row's gutter) let a full
column of illustration text render straight through it, landing directly under
the capability name and reading as overlapping text (issue #371, reported from
the field). The tint looked right in a static screenshot; the bug only appears
once the matrix is scrolled horizontally.

Two things this cost us that are worth remembering:

- **Hover and focus variants count.** The compact row's base `bg-white
  dark:bg-gray-900` was opaque, but `dark:group-hover:bg-gray-800/50` was not —
  a bleed that appears only while hovering, only in dark mode. Audit the whole
  variant set, not the base class.
- **The fix is the opaque composite, not "drop the tint".** Replacing the tint
  with plain `bg-white` makes the cell mask but no longer match its row;
  substituting the un-alpha'd token (`bg-blue-50`) overshoots badly (`#eff6ff`
  vs the `#fafcff` the row actually renders). Composite the real value in the
  browser — `ctx.fillStyle = base; fillRect; ctx.fillStyle = tint; fillRect;
  getImageData` gives the exact sRGB result — and use that literal, recording
  which token over which surface it came from.

The invariant, the current values, and the shared right-edge treatment live in
`app/views/frameworks/explorer/concerns/sticky_column.rb`; the opacity contract
is pinned by `test/system/frameworks/matrix_sticky_column_system_test.rb`.

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
> **Recency cap + load-older:** the feed reads only the most-recent
> `ActivityFeedQuery::STREAM_READ_LIMIT` events; when more exist *at framework
> focus*, a "Load older activity" footer appends the next (older) batch via a
> Turbo Stream and bumps the running count — cursor-paginated on `before:` (the
> oldest loaded event id) with a `loaded` running total. `activity_more_controller`
> issues the request; a live broadcast reload resets to the most-recent batch.
> Role-family / role / **level adds** now surface too (structural group,
> framework-level anchor; the level entry names its role — "Added L4 to EM ·
> Engineering Manager"). Collaborator entries name the person they concern
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
> cell-anchored with the level pinned; see §12a). Still deferred (note when
> adding): reorders. The
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

## File Reference

| File | Purpose |
|------|---------|
| `app/views/frameworks/show_view.rb` | Three-pane shell, stats bar, layout |
| `app/views/frameworks/matrix_frame_view.rb` | Turbo Frame wrapper for matrix endpoint |
| `app/views/frameworks/explorer/role_tree.rb` | Department → Family → Role tree; family list wrapped in the `role-tree-families` Turbo Frame; renders `RoleFamilyNameFrame` + `RoleNameFrame` for inline rename + the per-family edit-dialog trigger when `mode == :edit`; hides ghost roles/families in view mode, shows them (+ "No roles yet" + the "+ Add role" / "+ Add role family" triggers) in edit mode |
| `app/views/frameworks/explorer/role_family_name_frame.rb` | Role-family name + edit-mode inline rename editor (direct edit, no suggestion path) |
| `app/views/frameworks/explorer/role_family_edit_modal.rb` | Shared role-family dialog — `:edit` (per-family trigger, PATCH) or `:new` (tree-foot "+ Add role family", POST → `AddRoleFamily`); submit re-renders the `role-tree-families` frame so the family re-groups / appears ghost-wiggled |
| `app/views/frameworks/explorer/add_role_modal.rb` | Shared role modal — `:new` ("+ Add role" trigger, family implied, POST → `AddRole`) or `:edit` (role-row kebab, PATCH via id template → `UpdateRole`) |
| `app/views/frameworks/explorer/level_editor_modal.rb` | Shared "Edit levels" modal (embedded) — body is the `level-editor` Turbo Frame; opened by the role-row kebab. Carries the shared `frame-error` controller + `Kit::FrameLoadError` block (audit issue #365): an un-handled `turbo:frame-missing` otherwise renders Turbo's own "Content missing" into the editor, with no retry |
| `app/views/frameworks/explorer/level_editor_frame.rb` | Levels-editor frame body — per-row title/code saves, radio-with-clear entry flag, add row with in-frame errors; re-renders in place |
| `app/javascript/controllers/level_editor_form_controller.js` | Points the level-editor frame at the clicked role on `modal:open`; fires `org-structure:updated` after in-frame saves |
| `app/views/frameworks/explorer/concerns/ghost_entities.rb` | Ghost predicates (`published_role?` / `ghost_role?` / `ghost_role_family?`) + tooltip copy — "not visible in the published view yet", derived from published-level presence |
| `app/javascript/controllers/add_role_form_controller.js` | Prefills the role modal from its trigger (`:new` — family id + clears; `:edit` — action template + name/code/track); fires `org-structure:updated` after an edit; selection rides along via `tree-scope-fields` |
| `app/operations/operations/frameworks/{add_role_family,add_role}.rb` | Shared web + MCP operations — org-structure adds (shape-preserving, live; new entity is a ghost until publish) |
| `app/operations/operations/frameworks/add_level.rb` | Shared web + MCP operation — add a level (shape-changing: auto-opens a draft, deferred until publish; guards duplicate ordinals against the graph) |
| `app/views/frameworks/explorer/add_level_modal.rb` | Shared "new level" modal (ordinal + title + code + entry flag; role implied by the role-row kebab's "Add level…" trigger) → `Frameworks::LevelsController#create` |
| `app/javascript/controllers/add_level_form_controller.js` | Prefills the add-level modal from the role kebab's "Add level…" trigger (role id/name + next free ordinal); selection rides along via `tree-scope-fields` |
| `app/views/frameworks/explorer/department_name_frame.rb` | Department group header; inline-renameable in edit mode → bulk relabel of every family in the group |
| `app/javascript/controllers/role_family_edit_form_controller.js` | Prefills the role-family dialog from the trigger dataset (`:edit` fills, `:new` clears); copies the current `roles[]`/`track` selection from the URL so the re-rendered tree stays checked |
| `app/javascript/controllers/tree_scope_fields_controller.js` | Injects the current `roles[]`/`track` selection into a form at submit (`formdata` event) — used by the department-rename inline editor |
| `app/operations/operations/frameworks/rename_department.rb` | Shared web + MCP operation — bulk-rename a department across its role families (fans out to `UpdateRoleFamily`; blank target ungroups) |
| `app/controllers/frameworks/departments_controller.rb` | `PATCH /frameworks/:id/departments` — dispatch `RenameDepartment`, re-render the `role-tree-families` frame |
| `app/controllers/concerns/frameworks/role_tree_families_frame.rb` | Shared `role-tree-families` frame render (selection-preserving), used by the role-family + department controllers |
| `app/views/frameworks/explorer/role_name_frame.rb` | Role name + edit-mode inline rename editor (direct edit) |
| `app/views/frameworks/explorer/level_title_frame.rb` | Per-role level title + edit-mode inline rename editor (full-title header mode only) |
| `app/views/frameworks/explorer/matrix.rb` | Table container + empty state |
| `app/views/frameworks/explorer/matrix_header.rb` | Sticky column headers with responsive titles; renders `LevelTitleFrame` per role in full-title (≤3 roles) edit mode |
| `app/views/frameworks/explorer/matrix_category_group.rb` | Collapsible category with capability rows; sticky header renders CategoryNameFrame + CategoryDescriptionFrame |
| `app/views/frameworks/explorer/matrix_row.rb` | Compact + expanded capability row; row-actions kebab (`Kit::Dropdown`, unconditional in edit mode) — inline Approve/Reject of pending name/description edits + Discuss… + Move up/down (reorder) + Edit roles… (binding editor) + Archive (§11, §12, §12a) |
| `app/views/frameworks/explorer/matrix_cell.rb` | Expectation text + hover "Discuss…" button (§12a) + illustration indicator + pending-count pill (≥2); renders "+ Add expectation" for an empty-but-applicable cell (any edit-mode viewer) |
| `app/views/frameworks/explorer/illustration_frame.rb` | Real illustration row in expanded cell — pending-edit decoration, ↑/↓ reorder chevrons (edit-structure holders), pencil, then the ⋮ kebab (Approve/Reject when approvable + Discuss… + Archive…) |
| `app/views/frameworks/explorer/pending_illustration_frame.rb` | Ghost entry for pending-create illustration suggestions (edit mode only) — pencil (amend/alternative) + Approve/Reject kebab for tier-authority viewers |
| `app/views/frameworks/explorer/new_illustration_frame.rb` | "+" Add illustration affordance (edit mode only) |
| `app/views/frameworks/explorer/new_expectation_frame.rb` | "+ Add expectation" affordance for an empty-but-applicable cell (any edit-mode viewer; follows the suggest/approve path) |
| `app/views/frameworks/explorer/pending_expectation_frame.rb` | Editable ghost of a pending expectation-create suggestion (amber wavy underline + pencil → amend/alternative), shown instead of "+ Add expectation" while a proposal exists |
| `app/views/frameworks/explorer/capability_name_frame.rb` | Capability name + edit-mode inline editor |
| `app/views/frameworks/explorer/capability_description_frame.rb` | Capability description + edit-mode inline editor ("Add a description…" when blank) |
| `app/views/frameworks/explorer/category_name_frame.rb` | Category name + edit-mode inline editor |
| `app/views/frameworks/explorer/category_description_frame.rb` | Category description + edit-mode inline editor ("Add a description…" when blank) |
| `app/views/frameworks/explorer/archive_modal.rb` | Shared archive modal (capability + as-we-go migration mapping) — opened by the row kebab |
| `app/views/frameworks/explorer/add_capability_modal.rb` | Shared add-capability modal (name + description + role bindings) |
| `app/views/frameworks/explorer/add_category_modal.rb` | Shared add-category modal (name + description) |
| `app/views/frameworks/explorer/archive_category_modal.rb` | Shared archive-category modal (confirm + optional reason; no migration mapping) — opened by the header kebab |
| `app/views/frameworks/explorer/binding_editor_modal.rb` | Shared "Edit roles" modal (embedded) — body is the `binding-editor` Turbo Frame; opened by the row kebab. Same `frame-error` + `Kit::FrameLoadError` wiring as the level-editor modal (audit issue #365) — the frame-failure machinery is documented in [assessments.md](assessments.md)'s Stimulus controllers table, where it was extracted from the evidence modal |
| `app/views/frameworks/explorer/binding_editor_frame.rb` | Binding-editor frame body — lists role bindings (weight + Remove) + add-role form; re-renders in place on each action |
| `app/views/frameworks/publication_review_view.rb` | Publish-review page — validate/override migration mappings, then cut the version |
| `app/views/frameworks/explorer/expectation_text_frame.rb` | Expectation text + edit-mode inline editor |
| `app/views/frameworks/explorer/concerns/suggestion_decoration.rb` | Shared decoration class helper (wavy underline / strikethrough) + the squiggle's open-card click affordance (§10) |
| `app/views/frameworks/explorer/concerns/approval_kebab_items.rb` | Shared §12 Approve/Reject kebab machinery — items for the row kebab, standalone kebabs for expectation cells + illustrations |
| `app/controllers/concerns/frameworks/suggestion_authority.rb` | Resolves the viewer's `SuggestionApprovalAuthority` for controllers whose frame responses carry approval kebabs |
| `app/controllers/concerns/frameworks/suggestion_resolution_streams.rb` | Surgical inline approve/reject responses — Turbo Streams replacing just the affected entity's frame; nil → 204 → client full-refresh fallback (Hard-Won Lesson 23) |
| `app/views/frameworks/explorer/concerns/search_highlight.rb` | Phlex `<mark>` highlighting of search-match terms (§4a) — safe, token-AND, overlap-merged |
| `app/views/frameworks/explorer/concerns/inline_editable.rb` | Shared Phlex helpers for the edit pencil + inline form; `inline_editor_value` seeds the box with the pending proposal |
| `app/views/frameworks/suggestions/inline_indicator.rb` | Amber "N pending" count pill (used in matrix cells) |
| `app/models/frameworks/matrix_data_builder.rb` | Data transformation (merge levels, filter capabilities, keep empty categories in edit mode, per-field `latest_by_field` pending-edit descriptors) |
| `app/models/frameworks/suggestion_diff.rb` | Grapheme-level inline diff between original and proposed text; fallback on density threshold |
| `app/views/frameworks/suggestions/panel_frame.rb` | (Legacy) suggestion-only panel content — retained for the standalone suggestion index, no longer the context pane |
| `app/views/frameworks/activity/panel_frame.rb` | Context pane Turbo Frame content — activity feed (focus header + count + "Show all" clear link + filter chips + entry list + load-older footer + empty state) |
| `app/views/frameworks/activity/load_more.rb` | "Load older activity" footer (`#framework-activity-load-more`) — indication + affordance for the next batch |
| `app/views/frameworks/activity/count.rb` | Loaded-entry count (`#framework-activity-count`) — replaced by the load-older Turbo Stream |
| `app/views/frameworks/activity/show.turbo_stream.erb` | Load-older response — append older entries + replace the footer + the count |
| `app/javascript/controllers/activity_more_controller.js` | "Load older" — GET next batch as a Turbo Stream via `@rails/request.js` |
| `app/views/frameworks/activity/entry.rb` | One activity entry — `KIND_DOT` / `KIND_GROUP`, summary + context line + actor·timestamp footer, matrix-navigation data attrs, **inline Approve / Reject action row when pending + viewer-authorised** (§12) |
| `app/views/frameworks/explorer/reject_suggestion_modal.rb` | Shared reject-suggestion modal (optional reason) — explorer root, edit mode (§12) |
| `app/models/frameworks/suggestion_approval_authority.rb` | Per-viewer approval authority value object — computed once, gates the actionable feed (§12) |
| `app/operations/operations/frameworks/{approve,reject,amend,withdraw}_suggestion.rb` | Shared web + MCP suggestion-lifecycle operations (§12) |
| `app/operations/operations/frameworks/{request,resolve}_clarification.rb` | Shared web + MCP clarification operations — the non-proposal suggestion kind (§12a) |
| `app/views/frameworks/activity/clarification_actions.rb` | The "Resolve…" affordance on a pending clarification (feed entry + pane card) — opens the resolve modal (§12a) |
| `app/views/frameworks/explorer/resolve_clarification_modal.rb` | Shared resolve-clarification modal (required note) — explorer root, edit mode (§12a) |
| `app/javascript/controllers/resolve_clarification_form_controller.js` | Prefills the resolve modal from the trigger dataset; dispatches `suggestion:resolved` on success (§12a) |
| `app/views/frameworks/explorer/concerns/discuss_trigger.rb` | Shared "Discuss…" affordances — the hover button (cells) + menu item (kebabs) and their `discuss_*` anchor dataset (§12a) |
| `app/views/frameworks/explorer/request_clarification_modal.rb` | Shared "Start a discussion" modal (question + optional level) — explorer root, edit mode (§12a) |
| `app/javascript/controllers/request_clarification_form_controller.js` | Prefills the discuss modal from the trigger dataset; on success dispatches `suggestion:open-card` with the new suggestion id (§12a) |
| `app/controllers/frameworks/clarifications_controller.rb` | `POST /frameworks/:id/clarifications` — dispatch `RequestClarification`, answer 204 + `X-Suggestion-Id` (§12a) |
| `app/operations/operations/frameworks/{comment_on_suggestion,edit_suggestion_comment,delete_suggestion_comment}.rb` | Shared web + MCP suggestion-thread write operations (§13) |
| `app/operations/operations/frameworks/suggestion_get.rb` | MCP read drill-in — full suggestion (proposal + resolution + nested thread) |
| `app/contexts/frameworks/projections/suggestion_thread.rb` | Projects the three comment events into `framework_suggestion_comments`; broadcasts the activity signal (§13) |
| `app/read_models/framework_state/suggestion_comment.rb` | Thread read model — event-carried PK, soft delete, `for_suggestion`/`active` scopes |
| `app/policies/framework_suggestion_comment_policy.rb` | Record-level comment authz — author-only edit, author + admin delete |
| `app/controllers/frameworks/suggestion_comments_controller.rb` | Post / edit / delete thread comments from the pane card + detail page → the shared Operations |
| `app/views/frameworks/activity/suggestion_card_frame.rb` | The pane's suggestion-focus card — proposal + approve/reject + thread + composer (§8, §13) |
| `app/views/frameworks/suggestions/thread.rb` | The discussion thread (chronological, one-indent replies) shared by card + detail page |
| `app/views/frameworks/suggestions/comment_card.rb` | One thread comment — kebab (reply/edit/delete), tombstones, reply chips |
| `app/javascript/controllers/suggestion_action_controller.js` | Inline approve — POSTs `inline=1`, dispatches `suggestion:resolved` (§12) |
| `app/javascript/controllers/reject_suggestion_form_controller.js` | Prefills the reject modal from the trigger dataset; dispatches `suggestion:resolved` on success (§12) |
| `app/views/frameworks/activity/filter_chips.rb` | All / Suggestions / Edits / Structural / Lifecycle / Collaborators (client-side filter) |
| `app/javascript/controllers/framework_activity_controller.js` | Client-side filter-chip toggling of visible entry groups |
| `app/javascript/controllers/framework_explorer_controller.js` | Layout shell, pane toggle, role count |
| `app/javascript/controllers/tree_controller.js` | Role selection, solo mode, track filter |
| `app/javascript/controllers/matrix_controller.js` | Turbo Frame updates, row/category expansion, cell + category focus dispatch (shared with assessment) |
| `app/javascript/controllers/context_pane_controller.js` | Right-pane frame src + focus URL sync + activity-sync-signal observer (live reload) |
| `app/javascript/controllers/framework_search_controller.js` | Stats-bar text filter — debounced input → `framework-search:changed` (§4a) |
| `app/queries/frameworks/activity_feed_query.rb` | Reads the framework RES stream → reverse-chronological anchored activity entries; focus narrowing + `descriptor`. Names entities from the read model **supplemented by the creating event in the window** (so draft-added capabilities/expectations — deferred from the read model — are still named in "Added a capability" / binding entries), and pins the **level** on expectation entries ("Capability · L`n`") |
| `app/queries/frameworks/focused_suggestions_query.rb` | In-memory scope filter for the standalone suggestion index |
| `app/controllers/frameworks_controller.rb` | show / matrix / edit / edit_matrix actions (mode-aware) |
| `app/controllers/frameworks/activity_controller.rb` | `GET /frameworks/:id/activity` — renders the activity-feed panel (focus-narrowed); Turbo Stream branch serves the load-older batches |
| `app/contexts/frameworks/projections/published_state.rb` | `broadcast_framework_activity` nudges the per-framework activity stream (replay-guarded) |
| `app/operations/operations/frameworks/recent_activity.rb` | MCP read-parity tool over `ActivityFeedQuery` |
| `app/controllers/frameworks/suggestions_controller.rb` | Standalone suggestion list + detail; create/approve/reject/amend/withdraw all dispatch `Operations::Frameworks::*` (create → `SuggestCreate`/`SuggestDelete`, always pending). approve/reject are inline-aware — `inline=1` (feed/grid) → surgical Turbo Stream, else 204; non-inline → redirect (§12) |
| `app/controllers/frameworks/illustrations_controller.rb` | Inline edit/create on illustrations (PATCH → `SuggestEdit`, POST → `SuggestCreate` with the edit/suggest toggle) |
| `app/controllers/frameworks/capabilities_controller.rb` | Inline edit on capability name **or** description (PATCH → `SuggestEdit`); add a capability (POST → `AddCapability`). Resolves the capability from the graph (incl. draft-added — Lesson 17) |
| `app/controllers/frameworks/categories_controller.rb` | Inline edit on category name **or** description (PATCH → `SuggestEdit`); add a category (POST → `AddCategory`) |
| `app/controllers/frameworks/expectations_controller.rb` | Inline edit on expectation description (PATCH → `SuggestEdit` — resolves from the graph for draft-added, Lesson 17); author an expectation in an empty cell (POST → `SetBehaviouralExpectation`, suggest/approve path) |
| `app/controllers/frameworks/capability_archives_controller.rb` | Archive a capability from the row kebab (POST → `ArchiveCapability`) |
| `app/controllers/frameworks/capability_bindings_controller.rb` | Binding editor — index (frame) / create / update / destroy → `{Add,Update,Remove}CapabilityRoleBinding`, re-rendering the frame |
| `app/controllers/frameworks/category_archives_controller.rb` | Archive an empty category from the header kebab (POST → `ArchiveCategory`) |
| `app/controllers/frameworks/{role_families,roles,levels}_controller.rb` | Direct (PATCH) edits of role family / role / level from the tree + header → `Operations::Frameworks::{UpdateRoleFamily,UpdateRole,UpdateLevel}`; all three also serve POST creates from the add modals → `{AddRoleFamily,AddRole,AddLevel}` (`role_families`/`roles` re-render the `role-tree-families` frame; `levels` redirects to the edit explorer, selection preserved). `role_families` serves both the inline rename (re-renders the name frame) and the edit dialog (forwards changed fields only, re-renders the `role-tree-families` frame on the `Turbo-Frame` header). Direct edit, not the suggest path. |
| `app/controllers/frameworks/illustration_archives_controller.rb` | Archive an illustration from the expanded-row control (POST → `ArchiveIllustration`) |
| `app/controllers/frameworks/illustration_reorders_controller.rb` | Move an illustration before/after a sibling (POST → `ReorderIllustrations`; 204, client moves the DOM node) |
| `app/controllers/frameworks/category_reorders_controller.rb` | Move a category before/after a visible sibling (POST → `ReorderCategories`; 204 → `org-structure:updated` refresh) |
| `app/controllers/frameworks/capability_reorders_controller.rb` | Move a capability before/after a movable sibling in its category (POST → `ReorderCapabilities`; graph-resolved, 204 → refresh) |
| `app/javascript/controllers/reorder_move_controller.js` | Single-move POST button — on success dispatches `org-structure:updated` (matrix refresh) for entities that can't be DOM-moved in place |
| `app/javascript/controllers/reorder_list_controller.js` | ↑/↓ list reordering — POSTs the neighbour-relative move, repositions the item's node on success |
| `app/controllers/frameworks/publications_controller.rb` | Publish-review page (`new`) + publish the draft (`create` → `PublishVersion`) |
| `app/controllers/frameworks/migration_mappings_controller.rb` | Define/override a migration mapping on the publish-review page (POST → `DefineMigrationMapping`) |
| `app/operations/operations/frameworks/{add_capability,add_category,archive_capability,archive_category,archive_illustration,define_migration_mapping,publish_version}.rb` | Shared web + MCP operations for structural edits / publish (§11). `archive_capability`/`archive_illustration` are toggle+authority-driven (direct vs suggestion). |
| `app/operations/operations/frameworks/{add,update,remove}_capability_role_binding.rb` | Shared web + MCP binding operations — add/remove (shape-changing, draft) and weight/tolerance update (shape-preserving). |
| `app/operations/operations/frameworks/reorder_illustrations.rb` | Shared web + MCP operation — reorder one expectation × role's illustrations (complete-list, permutation-validated, shape-preserving). |
| `app/operations/operations/frameworks/reorder_categories.rb` | Shared web + MCP operation — reorder the active capability categories (complete-list, permutation-validated, shape-preserving). |
| `app/operations/operations/frameworks/reorder_capabilities.rb` | Shared web + MCP operation — reorder one category's capabilities (graph-validated so draft-added ones are included; shape-preserving). |
| `app/operations/operations/frameworks/set_behavioural_expectation.rb` | Shared web + MCP operation — author an expectation in an empty cell via the suggest/approve path (`suggest_create`: direct-apply with authority in editing mode, else a pending suggestion); guards against a duplicate at the same level. |
| `app/operations/operations/frameworks/{update_role_family,update_role,update_level}.rb` | Shared web + MCP operations — direct, shape-preserving org-structure renames (and role code/track, level code for MCP). `update_level` defers `is_entry` (no Boolean param support in `Operations::Base` yet). |
| `app/javascript/controllers/binding_editor_form_controller.js` | Points the binding-editor Turbo Frame at the clicked capability on `modal:open` |
| `app/javascript/controllers/frame_error_controller.js` | Shared lazy-frame failure state (error + Retry in place of a stuck "Loading…" or Turbo's "Content missing") — self-binds its five listeners in `connect()`; on the explorer it rides the binding-/level-editor modal bodies (audit issue #365) |
| `app/components/kit/frame_load_error.rb` | The hidden `role="alert"` block `frame-error` reveals — message built from `subject:` + `closeable:`, Retry, and a Close for modals |
| `app/policies/framework_policy.rb` | `edit?` (suggest bar, edit route) · `edit_structure?` / `add_capability?` / `add_category?` / `archive_capability?` / `update_role_family?` / `update_role?` / `update_level?` (edit-rights bar) · `publish?` / `define_migration_mapping?` (publish bar) |
| `app/controllers/concerns/framework_edit_mode.rb` | Reads the `framework_edit_mode` cookie → `:editing` or `:suggesting` |
| `app/operations/operations/frameworks/suggest_edit.rb` | Shared web + MCP operation — framework content edits (capability/category name + description, expectation + illustration text): authority-aware auto-approve in editing mode, pending suggestion otherwise; amends the author's pending edit on a field (→ `SuggestionAmended`) instead of stacking consecutive duplicates |
| `app/operations/operations/frameworks/{suggest_create,suggest_delete}.rb` | Shared web + MCP operations — the explicit "propose a change" endpoints (`SuggestCreate` defaults to pending, editing mode auto-applies with authority; `SuggestDelete` is always pending — the archive tools own direct-apply) |
| `app/javascript/controllers/edit_mode_toggle_controller.js` | Segmented Editing/Suggesting toggle; writes the cookie client-side |
| `app/javascript/controllers/modal_controller.js` | Generic modal; opens the overlay named by `data-modal-target-id` (lone-overlay fallback) — hosts the 4 shared structural modals + the reject-suggestion modal (Lesson 19) |
| `app/javascript/controllers/{add_capability_form,archive_form,mapping_form,archive_category_form}_controller.js` | Prefill the shared structural modals from the `modal:open` trigger dataset (§11) |
| `test/system/framework_explorer_system_test.rb` | System tests (desktop + mobile) |
| `test/system/frameworks/edit_mode_system_test.rb` | Edit vs view mode UI differences |
| `test/system/frameworks/explorer_context_pane_test.rb` | Focus context system tests (edit mode) |
| `test/system/frameworks/suggestion_thread_system_test.rb` | Suggestion card + thread system tests (pane + detail page) |
| `test/models/frameworks/matrix_data_builder_test.rb` | Builder unit tests (incl. text-filter scope + counts) |
| `test/components/frameworks/explorer/search_highlight_test.rb` | `<mark>` highlight concern unit tests |
| `test/models/frameworks/matrix_data_builder_mode_test.rb` | `mode:` filter unit tests |
| `test/models/frameworks/suggestion_diff_test.rb` | Inline-diff algorithm unit tests (examples, density fallback, graphemes, whitespace) |
| `test/queries/frameworks/focused_suggestions_query_test.rb` | Focus filter unit tests |

## Keeping This Document Current

This document must be updated whenever changes are made to the framework explorer's architecture, interaction patterns, component hierarchy, or Stimulus controllers. Specifically:

- **New design decisions** — add to the Key Design Decisions section with rationale
- **Bug fixes revealing non-obvious behaviour** — add to Hard-Won Lessons
- **New or modified components** — update the Component Hierarchy and File Reference
- **New Stimulus controllers or changed responsibilities** — update the Stimulus Controller Responsibilities section
- **New future extension points** — add to Future Extension Points

If a lesson or decision is superseded, update or remove the old entry rather than appending a contradiction.
