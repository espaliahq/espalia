# Framework Explorer — UX Design & Architecture

This document captures the design decisions, interaction patterns, and hard-won lessons from building the Framework Explorer. Consult this before modifying the explorer or building features that extend it.

> **See also:** [assessments.md](assessments.md) for the assessment extension of the matrix pattern.

## Overview

The Framework Explorer is a three-pane interactive view for browsing career frameworks. It renders a **capability x level matrix** filtered by user-selected roles, with a hierarchical role tree for navigation.

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
|  (future: context pane)                                                  |
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
    ├── framework_header (back link, name, badge)
    ├── stats_bar (role count toggle button, levels, capabilities, suggestion count toggle)
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
        │               │   └── name span     → matrix#focusCategory
        │               └── MatrixRow (per capability)
        │                   ├── compact row (click → matrix#toggleRow)
        │                   └── expanded row (illustrations, hidden)
        │                       └── expanded td (click → matrix#focusCell)
        └── aside[data-controller="context-pane"]  ← right pane (context feed)
            └── turbo-frame#suggestion-panel (Suggestions::PanelFrame)
```

### Data Flow

```
Controller (eager loads)
  → MatrixDataBuilder (filters in-memory, builds matrix structure)
    → ShowView / MatrixFrameView (renders Phlex components)
      → Stimulus controllers (manage interactivity)
```

The `MatrixDataBuilder` is the single source of truth for what the matrix displays. It operates entirely on eager-loaded ActiveRecord associations — no additional queries. This is safe because framework data is relatively small (100-200 capabilities, 50-100 roles).

## Key Design Decisions

### 1. Role Tree: Three-Level Hierarchy

**Department → Role Family → Role**

Departments are a display grouping stored as an optional `department` column on the `framework_role_families` read model (not event-sourced). Role families without a department appear ungrouped. This mirrors organisational structure without prescribing it.

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

**Pane visibility is independent**: focus actions never auto-open the pane. The pane opens only via the "N Suggestions" toggle. Focus changes update URL + frame `src` but are invisible until the user opens the pane — state and visibility are separate concerns.

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

Suggestions surface directly on the grid — not just in the context pane. The explorer has a shared visual vocabulary for "this entity has pending changes":

**Decoration concern** (`app/views/frameworks/explorer/concerns/suggestion_decoration.rb`):
- `PENDING_EDIT_CLASSES` — amber wavy underline (applied when `pending_edit_count > 0`, covers both pending edits and pending creates).
- `PENDING_DELETE_CLASSES` — red strikethrough (applied when `pending_delete_count > 0`).
- Delete wins over edit if both are non-zero.

**Where decoration is applied** — four sites, each pulling its count from `MatrixDataBuilder`'s `pending_suggestions` map:

| Component | Decorated text | Count source |
|-----------|----------------|--------------|
| `MatrixCategoryGroup` | Category name (in the sticky category header) | `category_data[:pending_suggestion_count]` |
| `MatrixRow` | Capability name (compact row, sticky left column) | `capability_data[:pending_suggestion_count]` |
| `MatrixCell` | Expectation text (compact cell) | `cell_data[:pending_suggestion_count]` |
| `IllustrationFrame` | Illustration text (expanded row) | `cell_data[:illustration_pending_edits][illustration_id]` |

**InlineIndicator pill** (`app/views/frameworks/suggestions/inline_indicator.rb`) — small amber "N pending" count badge. Currently rendered **only** by `MatrixCell`, and **only** when `pending_suggestion_count >= 2`. The threshold is deliberate: a single pending edit is already visible as the underline, so the pill exists to disambiguate *stacked* edits on the same expectation where the underline alone doesn't reveal how many proposals are in flight. Category / capability / illustration rows do not render the pill.

**Ghost entries for pending-create illustrations** (`app/views/frameworks/explorer/pending_illustration_frame.rb`) — pending `role_illustration` creates render inline in the expanded row as a wavy-underlined list item alongside the real illustrations for that role. They carry the same pencil-icon affordance as real illustrations: the suggestion's original author can amend the pending proposal; other collaborators submit an alternative suggestion. This keeps pending proposals visible *in situ* rather than only in the context pane, so reviewers see the illustration next to its peers.

**Data source invariants** — all pending counts are pre-aggregated by `MatrixDataBuilder` during the single eager-load pass. No view component queries the database for suggestion counts.

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

### matrix_controller.js
- **Turbo Frame update** (builds URL from selection, sets frame src)
- **Category collapse** (sibling row walking — triggered by chevron button only; the category name runs `focusCategory`)
- **Row expansion** (toggle hidden expanded row by capability ID). Dispatches `matrix:focus-changed` with `level: "capability"` on expand, `level: "framework"` on collapse.
- **Cell focus** (`focusCell` on expanded-row `<td>`) — dispatches `matrix:focus-changed` with `level: "cell"`. Ignores clicks that land on interactive children (buttons, links, inputs, forms, `[contenteditable]`) so inline editors inside the cell don't accidentally toggle focus.
- **Category focus** (`focusCategory` on the category name span). Dispatches `matrix:focus-changed` with `level: "category"`. Re-click clears to framework focus.
- **Panel navigation** (`navigateToEntity` on `suggestion:navigate` from context pane) — programmatically expands a row by capability ID, scrolls it into view, and dispatches `matrix:focus-changed`. For category-level navigation, scrolls to the category header.
- **URL sync** (pushState for shareability — explorer uses role/track params)
- **Assessment URL sync** (gated behind `urlSyncValue`) — syncs `?category=` and `?capability=` to browser URL, dims sibling rows on expansion. Only active in assessment views; explorer DOM never sets this value.
- **Shared** between explorer and assessment views — same collapse/expand logic applies

### context_pane_controller.js (explorer only)
Lives on the right-hand `<aside>` element. Sole owner of:
- **Panel frame src** (`#suggestion-panel`). Rebuilds the frame URL whenever focus or role selection changes; short-circuits when the computed URL equals the current `src` to prevent duplicate fetches.
- **Focus portion of the browser URL**. Pushes `?focus=`, `?category_id=`, `?capability_id=`, `?level_ordinal=` via `history.pushState()`; removes them when focus returns to `framework`.
- **Initial hydration**. Reads focus params from the browser URL on connect so deep-link reloads render the filtered panel on first frame fetch.

Listens at window scope via `data-action="tree:changed@window->context-pane#onTreeChanged matrix:focus-changed@window->context-pane#onFocusChanged"`.

Also dispatches:
- **`suggestion:navigate`** — fired by `focusSuggestion` when the user clicks a suggestion row body. Reads `data-nav-*` attributes from the clicked element and dispatches to window for `matrix_controller` to handle.

### Event contracts

| Event | Source | Detail |
|-------|--------|--------|
| `tree:changed` | `tree_controller` | `{ roleIds: string[], track: "ic" \| "management" \| "both" }` |
| `matrix:focus-changed` | `matrix_controller` | `{ level: "framework" \| "category" \| "capability" \| "cell", categoryId: string \| null, capabilityId: string \| null, levelOrdinal: number \| null, expectationId: string \| null }` — always fully specified |
| `suggestion:navigate` | `context_pane_controller` | `{ level: "category" \| "capability" \| "cell", categoryId: string \| null, capabilityId: string \| null, levelOrdinal: number \| null }` — triggers `matrix_controller#navigateToEntity` |

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

## Future Extension Points

### Context Pane: Comments & Activity Feed
The context pane currently shows suggested edits. Future content types — comments, activity log, evidence — will reuse the same focus protocol (`matrix:focus-changed` event, `FocusedSuggestionsQuery`-style in-memory filtering) and row anatomy (entity badge + kind badge, context line, preview). Each content type should follow the same principle: no internal categorisations in the UI, always show where-in-the-framework context, never truncate the context line.

## File Reference

| File | Purpose |
|------|---------|
| `app/views/frameworks/show_view.rb` | Three-pane shell, stats bar, layout |
| `app/views/frameworks/matrix_frame_view.rb` | Turbo Frame wrapper for matrix endpoint |
| `app/views/frameworks/explorer/role_tree.rb` | Department → Family → Role tree |
| `app/views/frameworks/explorer/matrix.rb` | Table container + empty state |
| `app/views/frameworks/explorer/matrix_header.rb` | Sticky column headers with responsive titles |
| `app/views/frameworks/explorer/matrix_category_group.rb` | Collapsible category with capability rows |
| `app/views/frameworks/explorer/matrix_row.rb` | Compact + expanded capability row |
| `app/views/frameworks/explorer/matrix_cell.rb` | Expectation text + illustration indicator + pending-count pill (≥2) |
| `app/views/frameworks/explorer/illustration_frame.rb` | Real illustration row in expanded cell, with pending-edit decoration |
| `app/views/frameworks/explorer/pending_illustration_frame.rb` | Ghost entry for pending-create illustration suggestions |
| `app/views/frameworks/explorer/concerns/suggestion_decoration.rb` | Shared decoration class helper (wavy underline / strikethrough) |
| `app/views/frameworks/suggestions/inline_indicator.rb` | Amber "N pending" count pill (used in matrix cells) |
| `app/models/frameworks/matrix_data_builder.rb` | Data transformation (merge levels, filter capabilities, pending-suggestion counts) |
| `app/views/frameworks/suggestions/panel_frame.rb` | Context pane Turbo Frame content (focused suggestion list + focus header + "Show all" clear link + empty state) |
| `app/javascript/controllers/framework_explorer_controller.js` | Layout shell, pane toggle, role count |
| `app/javascript/controllers/tree_controller.js` | Role selection, solo mode, track filter |
| `app/javascript/controllers/matrix_controller.js` | Turbo Frame updates, row/category expansion, cell + category focus dispatch (shared with assessment) |
| `app/javascript/controllers/context_pane_controller.js` | Right-pane frame src + focus URL sync |
| `app/queries/frameworks/focused_suggestions_query.rb` | In-memory scope filter for suggestion panel |
| `app/controllers/frameworks_controller.rb` | show + matrix actions |
| `app/controllers/frameworks/suggestions_controller.rb` | Suggestion list + panel-layout branch |
| `test/system/framework_explorer_system_test.rb` | System tests (desktop + mobile) |
| `test/system/frameworks/explorer_context_pane_test.rb` | Focus context system tests |
| `test/models/frameworks/matrix_data_builder_test.rb` | Builder unit tests |
| `test/queries/frameworks/focused_suggestions_query_test.rb` | Focus filter unit tests |

## Keeping This Document Current

This document must be updated whenever changes are made to the framework explorer's architecture, interaction patterns, component hierarchy, or Stimulus controllers. Specifically:

- **New design decisions** — add to the Key Design Decisions section with rationale
- **Bug fixes revealing non-obvious behaviour** — add to Hard-Won Lessons
- **New or modified components** — update the Component Hierarchy and File Reference
- **New Stimulus controllers or changed responsibilities** — update the Stimulus Controller Responsibilities section
- **New future extension points** — add to Future Extension Points

If a lesson or decision is superseded, update or remove the old entry rather than appending a contradiction.
