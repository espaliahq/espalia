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
- The four inline-edit controllers (`IllustrationsController`, `CapabilitiesController`, `CategoriesController`, `ExpectationsController`) `include FrameworkEditMode` and dispatch via the shared [`InlineSuggestedEdits`](../../app/controllers/concerns/inline_suggested_edits.rb) concern (`submit_inline_suggested_edit`), passing `mode: framework_edit_mode`. (`CapabilitiesController#update` **and** `CategoriesController#update` each handle **name or description** — whichever field the inline editor submitted — re-rendering the matching frame.)
- **Consecutive edits by the same author amend, they don't stack.** When the author already has a *pending* edit on the same `(entity, field)`, `submit_inline_suggested_edit` routes the new value through `#amend_suggestion` (→ `SuggestionAmended`) instead of a second `#suggest_edit`. So in Suggesting mode (and for any non-authority user) a field carries **one** pending suggestion per author — the all-suggestions page and activity feed never show consecutive duplicate suggestions on the same field by the same person; the 2nd+ edit renders as a distinct "Amended a … suggestion" feed entry. (In Editing mode an authority-holder's edit auto-approves immediately, so no pending suggestion lingers to amend — each applied change is its own audit event. Different authors still produce separate pending suggestions on the same field, so the §10 "stacked edits" multi-author case is unchanged.) **The same amend-on-duplicate rule covers `behavioural_expectation` *creates*** authored via "+ Add expectation": `Operations::Frameworks::SetBehaviouralExpectation` amends the author's existing pending create for that cell instead of stacking a second proposal. Because `apply_suggested_creation` reads `proposed_attributes` but an amend only updates `suggested_value`, the operation/aggregate fold the amended value back into the content field (`Frameworks::Aggregate::CREATE_CONTENT_FIELD`) so approval applies the latest value — and create/delete proposals are in `ActivityFeedQuery::PROPOSAL_KINDS`, so an amended create supersedes its original feed entry (only the latest stays actionable).
- `SuggestionsController#create` (the explicit "propose a change" endpoint for full-form creates/deletes) is intentionally **not** wired — it always submits as pending regardless of the toggle.
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

The matrix reads from the `Frameworks::ExplorerGraph` snapshot — a persistent JSON hash tree written atomically with every framework event by `Repository#with_framework`. The explorer no longer eager-loads the `FrameworkState::*` AR tree; that substrate remains for assessments, reporting, HRIS, and the full suggestions index. See `docs/architecture/framework-edit-mode-benchmarks.md` for why (read latency is ~6 ms p50 at Small, ~19 ms at Medium — versus hundreds of ms for AR eager-load or aggregate replay).

`MatrixDataBuilder` is the single source of truth for what the matrix displays. Operates entirely in-memory on the duck-typed graph — no additional queries. Framework size stays in the 100–200 capability / 50–100 role range.

## Key Design Decisions

### 1. Role Tree: Three-Level Hierarchy

**Department → Role Family → Role**

Departments are a display grouping — a free-text `department` string that is an **event-sourced** property of the role family (`RoleFamilyAdded`/`RoleFamilyUpdated`, projected to the `framework_role_families.department` column). Role families without a department appear ungrouped. Moving a family between departments is just editing the string (no department entity); a brand-new string creates a group, emptying the last family out of one removes it. This mirrors organisational structure without prescribing it. Edited via the role-family edit dialog (§11).

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

**Pending-change vocabulary (NON-NEGOTIABLE): the wiggle is the universal "differs from published" signal — never a pill.** The amber wavy underline ("the wiggle", `PENDING_EDIT_CLASSES`) marks any text that is **not in the published framework**, whether it's a pending suggestion *or* a change already applied into the open draft (added/edited in draft, not yet published). Do **not** add a "New in draft"/"Draft"/"Unpublished" pill or badge for this — the wiggle says it. Apply it via `suggestion_text_classes(added_in_draft: …)` (it returns the wiggle for `added_in_draft` just as it does for a pending edit), and pair it with `draft_change_title(added_in_draft)` so the meaning is conveyed non-visually (a `title` tooltip — accessibility, since the wiggle is otherwise colour/decoration-only). The one explicit badge that remains is **"Pending archive"**, because *removal* is a distinct state (the row is also struck through), not merely "differs from published".

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
  publish). *(Illustrations get the same unified, toggle-driven Archive — a
  hover-revealed archive control on each illustration in the expanded row
  (`IllustrationFrame`) → `Operations::Frameworks::ArchiveIllustration`: direct
  `remove_role_illustration` vs `suggest_delete("role_illustration")`, no
  migration mapping since illustrations carry no ratings.)*
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
  specific level. The inline UI is **rename-only** today — the Operations also
  accept role code/track and level code for MCP, and `is_entry` is deferred until
  `Operations::Base` grows Boolean-param support.
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
   (One-pending-suggestion-per-author-per-field is enforced upstream by the
   `InlineSuggestedEdits` amend-on-consecutive-edit concern; multi-author stacking
   on the same field is unchanged.)
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
4. **Resolution updates every affected frame and broadcasts live.** Approve/reject
   answer **204** (flagged `inline=1`) so Turbo neither navigates nor blanks the
   modal. The **feed** reloads off the existing activity broadcast
   (`broadcast_framework_activity`, replay-guarded; the actor sees their own
   resolution). The acting user's **matrix** refreshes client-side: the action
   dispatches a window `suggestion:resolved` → `matrix#refresh` (re-fetches the
   frame with the current filter axes) so the inline diff clears. Matrix refresh
   is acting-user-only by design — feed-live / matrix-not (Hard-Won Lesson 21).
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

**Two surfaces, one machinery.** The same pattern drives a second surface: the
**matrix row-actions kebab** (`MatrixRow`, a `Kit::Dropdown`). When a capability
has a pending name / description edit the viewer can approve, the kebab gains
**Approve / Reject «field» change** items (alongside **Archive…**, offered to
any suggest-rights viewer — see §11). They reuse the *exact* same pieces — `suggestion-action`
(inline approve, `inline=1` → 204), the root reject modal, and
`suggestion:resolved` → `matrix#refresh` — so approving from the grid and from
the feed are the same operation with the same live-update wiring (the feed
reloads via broadcast either way). The per-viewer authority is threaded into the
matrix the same way `can_edit_structure` is: controller → `Matrix` →
`MatrixCategoryGroup` → `MatrixRow`. `matrix#toggleRow` already ignores clicks
inside `[data-controller~='dropdown']`, so opening the kebab never expands the
row. Expectation / illustration edits are not (yet) on the grid kebab — the feed
covers those.

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
- **Panel navigation** (`navigateToEntity` on `suggestion:navigate` from context pane) — programmatically expands a row by capability ID, scrolls it into view, and dispatches `matrix:focus-changed`. For category-level navigation, scrolls to the category header.
- **Resolution refresh** (`refresh` on `suggestion:resolved`) — re-fetches the matrix frame with the current filter axes so an inline approve/reject in the feed clears the now-resolved inline diff for the acting user (§12, Hard-Won Lesson 21).
- **URL sync** (pushState for shareability — explorer uses role/track params)
- **Assessment URL sync** (gated behind `urlSyncValue`) — syncs `?category=` and `?capability=` to browser URL, dims sibling rows on expansion. Only active in assessment views; explorer DOM never sets this value.
- **Shared** between explorer and assessment views — same collapse/expand logic applies

### context_pane_controller.js (edit mode only)
Lives on the right-hand `<aside>` element. Sole owner of:
- **Panel frame src** (`#suggestion-panel`). Rebuilds the frame URL whenever focus, role selection, or a fresh suggestion submission occurs. Short-circuits when the computed URL equals the current `src` to prevent duplicate fetches. Forces a reload on `onSuggestionSubmitted` so a just-landed pending row surfaces even if the URL didn't change.
- **Focus portion of the browser URL**. Pushes `?focus=`, `?category_id=`, `?capability_id=`, `?level_ordinal=` via `history.pushState()`; removes them when focus returns to `framework`.
- **Initial hydration**. Reads focus params from the browser URL on connect so deep-link reloads render the filtered panel on first frame fetch. Unconditionally primes the frame `src` on connect because the pane is visible from initial render in edit mode (no lazy-until-open grace period — see Hard-Won Lesson 14).
- **Live reload**. Observes the hidden `#framework-activity-sync-signal` element (a `signal` target). `PublishedState#broadcast_framework_activity` replaces it on every feed-relevant event via the per-framework `framework_activity` Turbo stream; the observer reloads the feed frame unconditionally (no self-suppression — the feed frame is the only thing that re-fetches, so there's no matrix flicker, and the actor should see their own entry). Mirrors `assessment_sync_controller`.

Listens at window scope for:
- `tree:changed@window->context-pane#onTreeChanged`
- `matrix:focus-changed@window->context-pane#onFocusChanged`
- `suggestion:submitted@window->context-pane#onSuggestionSubmitted`

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

### suggestion_action_controller.js (edit mode only)
Wraps the inline **Approve** button on an actionable feed entry. `approve` POSTs to the suggestion's approve endpoint (`inline=1` → 204) via `@rails/request.js`; on success dispatches the window `suggestion:resolved` event (→ `matrix#refresh`) and leaves the feed to reload off the activity broadcast. Reject is *not* handled here — it always opens the shared modal (§12).

### reject_suggestion_form_controller.js (edit mode only)
Backs the shared reject-suggestion modal. On `modal:open` it self-gates on `rejectSuggestionId`, points the form at that suggestion's reject endpoint (a `__SID__` path template), fills the entity label + proposed-value preview, and clears the reason. On a successful submit it dispatches `suggestion:resolved`. The modal closes via `modal#submitted`; the feed reloads via broadcast (§12).

### Event contracts

| Event | Source | Detail |
|-------|--------|--------|
| `tree:changed` | `tree_controller` | `{ roleIds: string[], track: "ic" \| "management" \| "both" }` |
| `framework-search:changed` | `framework_search_controller` | `{ query: string }` — trimmed text filter; triggers `matrix_controller#updateSearch` (window-scoped, since the search box sits outside the matrix element). See §4a. |
| `matrix:focus-changed` | `matrix_controller` | `{ level: "framework" \| "category" \| "capability" \| "cell", categoryId: string \| null, capabilityId: string \| null, levelOrdinal: number \| null, expectationId: string \| null }` — always fully specified |
| `suggestion:navigate` | `context_pane_controller` | `{ level: "category" \| "capability" \| "cell", categoryId: string \| null, capabilityId: string \| null, levelOrdinal: number \| null }` — triggers `matrix_controller#navigateToEntity` |
| `suggestion:submitted` | `inline_editor_controller` | `{ formAction: string }` — fired on successful `turbo:submit-end`. Triggers `context_pane_controller#onSuggestionSubmitted`, which forces the panel frame to reload so a just-landed pending row appears without a page refresh. |
| `suggestion:resolved` | `suggestion_action_controller` (approve) / `reject_suggestion_form_controller` (reject) | no detail — fired on a successful inline approve/reject. Triggers `matrix_controller#refresh` so the acting user's grid drops the now-resolved inline diff. The feed reloads separately via the activity broadcast (§12, Hard-Won Lesson 21). |

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

### 21. Inline resolution must answer 204, and the matrix refreshes client-side

Two halves of the "actionable feed entry" wiring that are easy to get wrong:

- **204, not 200.** A Turbo form submit (the reject modal) that gets a `200` with
  an empty body makes Turbo Drive render the empty body — **blanking the page**.
  `head :no_content` (204) makes Turbo do nothing: the modal closes via
  `turbo:submit-end` and the page is untouched. (The approve path uses
  `@rails/request.js`, which doesn't navigate regardless, but 204 is correct there
  too.)
- **Feed-live, matrix-not.** The feed reloads for everyone via the activity
  broadcast, but the matrix deliberately does **not** live-reload (it would flicker
  / reset scroll for other viewers mid-edit). So an inline approve must refresh the
  **acting user's** matrix itself — a window `suggestion:resolved` event →
  `matrix#refresh` (re-fetch with the current `roles[]`/`track`/`q` axes). Other
  viewers pick up the applied edit on their next interaction. Symmetric: a future
  grid-side approve must refresh the feed the same way.

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
> Still deferred (note when adding): role/level/binding structural events,
> reorders, and threaded suggestion comments (`SuggestionCommented` unwired). The
> historical `Suggestions::PanelFrame` + `FocusedSuggestionsQuery` remain for the
> standalone suggestion index, not the pane.

**Every action a user can take on a framework MUST produce an entry in the
activity feed.** That includes the full suggestion lifecycle (submitted /
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
| `app/views/frameworks/explorer/role_tree.rb` | Department → Family → Role tree; family list wrapped in the `role-tree-families` Turbo Frame; renders `RoleFamilyNameFrame` + `RoleNameFrame` for inline rename + the per-family edit-dialog trigger when `mode == :edit` |
| `app/views/frameworks/explorer/role_family_name_frame.rb` | Role-family name + edit-mode inline rename editor (direct edit, no suggestion path) |
| `app/views/frameworks/explorer/role_family_edit_modal.rb` | Shared role-family edit dialog (name + description + department-with-`<datalist>`); submit re-renders the `role-tree-families` frame so the family re-groups |
| `app/javascript/controllers/role_family_edit_form_controller.js` | Prefills the role-family edit dialog from the trigger dataset; copies the current `roles[]`/`track` selection from the URL so the re-rendered tree stays checked |
| `app/views/frameworks/explorer/role_name_frame.rb` | Role name + edit-mode inline rename editor (direct edit) |
| `app/views/frameworks/explorer/level_title_frame.rb` | Per-role level title + edit-mode inline rename editor (full-title header mode only) |
| `app/views/frameworks/explorer/matrix.rb` | Table container + empty state |
| `app/views/frameworks/explorer/matrix_header.rb` | Sticky column headers with responsive titles; renders `LevelTitleFrame` per role in full-title (≤3 roles) edit mode |
| `app/views/frameworks/explorer/matrix_category_group.rb` | Collapsible category with capability rows; sticky header renders CategoryNameFrame + CategoryDescriptionFrame |
| `app/views/frameworks/explorer/matrix_row.rb` | Compact + expanded capability row; row-actions kebab (`Kit::Dropdown`) — inline Approve/Reject of pending name/description edits + Edit roles… (binding editor) + Archive (§11, §12) |
| `app/views/frameworks/explorer/matrix_cell.rb` | Expectation text + illustration indicator + pending-count pill (≥2); renders "+ Add expectation" for an empty-but-applicable cell (any edit-mode viewer) |
| `app/views/frameworks/explorer/illustration_frame.rb` | Real illustration row in expanded cell, with pending-edit decoration + edit-mode pencil |
| `app/views/frameworks/explorer/pending_illustration_frame.rb` | Ghost entry for pending-create illustration suggestions (edit mode only) |
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
| `app/views/frameworks/explorer/binding_editor_modal.rb` | Shared "Edit roles" modal (embedded) — body is the `binding-editor` Turbo Frame; opened by the row kebab |
| `app/views/frameworks/explorer/binding_editor_frame.rb` | Binding-editor frame body — lists role bindings (weight + Remove) + add-role form; re-renders in place on each action |
| `app/views/frameworks/publication_review_view.rb` | Publish-review page — validate/override migration mappings, then cut the version |
| `app/views/frameworks/explorer/expectation_text_frame.rb` | Expectation text + edit-mode inline editor |
| `app/views/frameworks/explorer/concerns/suggestion_decoration.rb` | Shared decoration class helper (wavy underline / strikethrough) |
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
| `app/controllers/frameworks/suggestions_controller.rb` | Standalone suggestion list + detail; approve/reject/amend/withdraw dispatch `Operations::Frameworks::*`. approve/reject are format-aware — `inline=1` (feed/grid) → 204, else redirect (§12) |
| `app/controllers/frameworks/illustrations_controller.rb` | Inline edit/create on illustrations (PATCH/POST) |
| `app/controllers/frameworks/capabilities_controller.rb` | Inline edit on capability name **or** description (PATCH); add a capability (POST → `AddCapability`). Resolves the capability from the graph (incl. draft-added — Lesson 17) |
| `app/controllers/frameworks/categories_controller.rb` | Inline edit on category name **or** description (PATCH); add a category (POST → `AddCategory`) |
| `app/controllers/frameworks/expectations_controller.rb` | Inline edit on expectation description (PATCH — resolves from the graph for draft-added, Lesson 17); author an expectation in an empty cell (POST → `SetBehaviouralExpectation`, suggest/approve path) |
| `app/controllers/frameworks/capability_archives_controller.rb` | Archive a capability from the row kebab (POST → `ArchiveCapability`) |
| `app/controllers/frameworks/capability_bindings_controller.rb` | Binding editor — index (frame) / create / update / destroy → `{Add,Update,Remove}CapabilityRoleBinding`, re-rendering the frame |
| `app/controllers/frameworks/category_archives_controller.rb` | Archive an empty category from the header kebab (POST → `ArchiveCategory`) |
| `app/controllers/frameworks/{role_families,roles,levels}_controller.rb` | Direct (PATCH) edits of role family / role / level from the tree + header → `Operations::Frameworks::{UpdateRoleFamily,UpdateRole,UpdateLevel}`. `role_families` serves both the inline rename (re-renders the name frame) and the edit dialog (forwards changed fields only, re-renders the `role-tree-families` frame on the `Turbo-Frame` header). Direct edit, not the suggest path. |
| `app/controllers/frameworks/illustration_archives_controller.rb` | Archive an illustration from the expanded-row control (POST → `ArchiveIllustration`) |
| `app/controllers/frameworks/publications_controller.rb` | Publish-review page (`new`) + publish the draft (`create` → `PublishVersion`) |
| `app/controllers/frameworks/migration_mappings_controller.rb` | Define/override a migration mapping on the publish-review page (POST → `DefineMigrationMapping`) |
| `app/operations/operations/frameworks/{add_capability,add_category,archive_capability,archive_category,archive_illustration,define_migration_mapping,publish_version}.rb` | Shared web + MCP operations for structural edits / publish (§11). `archive_capability`/`archive_illustration` are toggle+authority-driven (direct vs suggestion). |
| `app/operations/operations/frameworks/{add,update,remove}_capability_role_binding.rb` | Shared web + MCP binding operations — add/remove (shape-changing, draft) and weight/tolerance update (shape-preserving). |
| `app/operations/operations/frameworks/set_behavioural_expectation.rb` | Shared web + MCP operation — author an expectation in an empty cell via the suggest/approve path (`suggest_create`: direct-apply with authority in editing mode, else a pending suggestion); guards against a duplicate at the same level. |
| `app/operations/operations/frameworks/{update_role_family,update_role,update_level}.rb` | Shared web + MCP operations — direct, shape-preserving org-structure renames (and role code/track, level code for MCP). `update_level` defers `is_entry` (no Boolean param support in `Operations::Base` yet). |
| `app/javascript/controllers/binding_editor_form_controller.js` | Points the binding-editor Turbo Frame at the clicked capability on `modal:open` |
| `app/policies/framework_policy.rb` | `edit?` (suggest bar, edit route) · `edit_structure?` / `add_capability?` / `add_category?` / `archive_capability?` / `update_role_family?` / `update_role?` / `update_level?` (edit-rights bar) · `publish?` / `define_migration_mapping?` (publish bar) |
| `app/controllers/concerns/framework_edit_mode.rb` | Reads the `framework_edit_mode` cookie → `:editing` or `:suggesting` |
| `app/controllers/concerns/inline_suggested_edits.rb` | `submit_inline_suggested_edit` — amends the author's pending edit on a field (→ `SuggestionAmended`) or creates a fresh suggestion; prevents consecutive duplicate suggestions |
| `app/javascript/controllers/edit_mode_toggle_controller.js` | Segmented Editing/Suggesting toggle; writes the cookie client-side |
| `app/javascript/controllers/modal_controller.js` | Generic modal; opens the overlay named by `data-modal-target-id` (lone-overlay fallback) — hosts the 4 shared structural modals + the reject-suggestion modal (Lesson 19) |
| `app/javascript/controllers/{add_capability_form,archive_form,mapping_form,archive_category_form}_controller.js` | Prefill the shared structural modals from the `modal:open` trigger dataset (§11) |
| `test/system/framework_explorer_system_test.rb` | System tests (desktop + mobile) |
| `test/system/frameworks/edit_mode_system_test.rb` | Edit vs view mode UI differences |
| `test/system/frameworks/explorer_context_pane_test.rb` | Focus context system tests (edit mode) |
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
