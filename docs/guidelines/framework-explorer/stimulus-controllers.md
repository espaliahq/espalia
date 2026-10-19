# Framework Explorer — Stimulus Controllers

> Part of the [framework-explorer.md](../framework-explorer.md) guide set. Read this when: changing or adding a Stimulus controller the explorer uses, or an event it dispatches or listens for.

## Stimulus Controller Responsibilities

### framework_explorer_controller.js
- **Role pane toggle** (desktop: inline show/hide, mobile: fixed overlay)
- **Activity (context) pane toggle** — same two modes; below `lg` a
  right-anchored fixed overlay, closed by default (§7)
- **Click-outside close** on mobile for BOTH panes (via `useClickOutside`). One
  `clickOutside` callback serves both registrations — stimulus-use has no
  per-element callback name — so it re-checks containment itself rather than
  trusting which one fired, and registers each element only once.
- **Esc close** (`closeOverlayPanes`) — narrow viewports only. Both it and the
  outside-tap path gate on `#somethingElseIsOpen` (no open modal overlay, no
  open `[role="menu"]`)
- **Focus hand-off** for the activity overlay — into the pane on open, back to
  the Activity toggle on every close
- **`--explorer-offset`** — measures the chrome above the explorer
  (`ResizeObserver` on the header + `resize@window`) so the layout is exactly
  the leftover viewport (§7)
- **Breakpoint crossing** (`viewportChanged`) — strips an overlay's inline
  styles and resets each pane to its default for the new width
- **Role count update** when tree selection changes
- **Toggle affordance** (chevron rotation, active state styling, `aria-expanded`)

### tree_controller.js
- **Checkbox management** (role toggle, family bulk toggle, indeterminate state)
- **Solo mode** (save/restore selection state)
- **Track filter** (IC / Management / Both — hides roles, updates family state)
- **Event dispatch** (`tree:changed` with `{roleIds, track}`, bubbles to parent)

### tree_scope_fields_controller.js
Injects the current matrix scope — `roles[]`, `track` and the text filter `q`,
read from the browser URL `matrix_controller` keeps in sync — into a form at
submit time via the `formdata` event. Two callers, one need: the
department-rename editor re-renders the role-tree frame and must keep the
checkboxes checked, and **every write that answers a surgical Turbo Stream**
must re-render its rows against the scope the grid around them was built with
(§11b). Submit-time, not connect-time: the selection can change after the modal
opens.

### framework_search_controller.js
Lives on the stats-bar search box. Debounces keystrokes (250ms, `useDebounce`)
and dispatches the window-scoped `framework-search:changed` event with the
trimmed query; Esc and the inline × clear immediately. Toggles the × affordance
on input. Does NOT touch the matrix or URL itself — that's `matrix_controller`'s
job via `updateSearch`. See §4a.

### matrix_controller.js
- **Turbo Frame update** (builds URL from selection, sets frame src) —
  **debounced**: both filter axes share one 300ms trailing timer, so a burst of
  checkbox toggles is one fetch (#383). The URL push stays immediate; the
  unsaved-editor confirm stays at interaction time (the prompt belongs to the
  click that would discard the work, and confirming clears the dirty flag so a
  burst asks once).
- **Busy state** (`busy` target + `frameSettled`) — the indicator is shown from
  the click and cleared on the frame's load / miss / fetch-error, so it covers
  the debounce window Turbo's own `busy` attribute cannot see.
- **Text-filter update** (`updateSearch` on `framework-search:changed`) — merges
  the query with the role/track scope read back from the browser URL, via the
  shared `#rebuildMatrixFrame`. See §4a.
- **Category collapse** (sibling row walking — triggered by chevron button only; the category name runs `focusCategory`)
- **Row expansion** (toggle hidden expanded row by capability ID). Dispatches `matrix:focus-changed` with `level: "capability"` on expand, `level: "framework"` on collapse. **The first expand fetches the row's content** (`#ensureExpandedRowLoaded`): the matrix ships each expanded row as a placeholder (`data-loaded="false"` + `data-expanded-src`), the controller GETs the loaded `<tr>` via `@rails/request.js`, swaps it in preserving the accordion state, and shows the placeholder's server-rendered error line + Retry (`retryExpandedRow`) on failure. `#expandRow` resolves with the loaded row, so `navigateToEntity` awaits it before looking for the target cell / suggestion anchor (Hard-Won Lesson 25).
- **Cell focus** (`focusCell` on expanded-row `<td>`) — dispatches `matrix:focus-changed` with `level: "cell"`. Ignores clicks that land on interactive children (buttons, links, inputs, forms, `[contenteditable]`) so inline editors inside the cell don't accidentally toggle focus.
- **Category focus** (`focusCategory` on the category name span). Dispatches `matrix:focus-changed` with `level: "category"`. Re-click clears to framework focus.
- **Panel navigation** (`navigateToEntity` on `suggestion:navigate` from context pane) — programmatically expands a row by capability ID, scrolls it into view, and dispatches `matrix:focus-changed`. For category-level navigation, scrolls to the category header. When the entry names a **pending suggestion**, scrolls to that suggestion's decorated element (`[data-suggestion-id]` anchor) and pulses `.suggestion-nav-highlight` on it — an expanded cell can be taller than the viewport, so cell-centering alone leaves the example off-screen; the cell/row scroll is the anchor-less fallback (the cell gets the same pulse).
- **Resolution refresh** (`refresh` on `suggestion:resolved`) — when the response was not surgical (`detail.surgical` false), re-fetches the matrix frame with the current filter axes so an inline approve/reject in the feed clears the now-resolved inline diff for the acting user; a surgical response already replaced the frame, so it skips the fetch (§12, Hard-Won Lesson 21).
- **Squiggle → suggestion card** (`openSuggestionCard` on a decorated pending change) — stops the row/cell click and dispatches the window `suggestion:open-card` event; the context pane renders the card and a collapsed pane reveals itself (§10).
- **Sticky geometry** (`#publishStickyGeometry` / `#observeStickyGeometry`) —
  measures the sticky header cell and the tallest category band with a
  `ResizeObserver` and publishes `--matrix-header-h` / `--matrix-category-h` on
  the explorer root, re-observing on every matrix frame load. See *Sticky
  Positioning*.
- **Sticky-stack guard** (`#guardRowClearsStickyStack`, after
  `#anchorCapabilityTop` settles) — asks `elementFromPoint` whether the expanded
  row's name line is really the topmost thing at its own coordinates, and nudges
  the scroll if the sticky header answered instead. `scrollIntoView` resolves
  `scroll-margin` once and never retargets (#382).
- **On-grid focus** (`#applyGridFocus`) — stamps `data-focused` on the focused
  row / level cells / category band, diffed against the previous set and
  re-applied on frame load and after an expanded row's content lands. See §8.
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

### field_editor_controller.js (edit mode only) — ONE editor for the whole explorer
Mounted **once** on the explorer root; every editable text ships display markup
plus `data-editor-*` data and a pencil carrying `data-action="field-editor#open"`.
On open it clones `FieldEditorTemplate` into the host — so editors inserted late
(the on-demand expanded row, a frame re-render) work with no extra wiring, and
the matrix ships **zero** pre-rendered forms/textareas (#379: 374 → 0 of each,
485 → 111 controller mounts, −18% bytes on the seeded framework).

Host contract (see the controller's header comment for the full list):
`data-editor-action` / `-method` / `-field` / `-value` / `-rows` / `-label` /
`-placeholder` / `-entity` / `-outcome` / `-submit-label` / `-turbo-frame` /
`-form-class` / `-form-controller` / `-extra` (JSON hidden fields) /
`-error`; inside it, `[data-editor-display]` is the read-mode element.

- **Open / cancel** — `open` clones, fills, focuses and hides the display element
  with an *inline* `display:none` (a `hidden` class loses to the element's own
  `flex`/`inline-flex` — [assessments Lesson 17](../assessments/lessons.md)). Only one editor at a time:
  opening another confirms before discarding unsaved text.
- **Keyboard** — Esc cancels, Cmd/Ctrl+Enter saves, the textarea auto-grows.
- **Width** — the form is `w-full min-w-0` of its host, and the visible hint text
  is `sr-only`, so opening one in a level column doesn't renegotiate the
  auto-layout table's column widths (Hard-Won Lesson 27).
- **Save vs Propose** — derived from `approvalsValue` (server-computed per-entity
  authority) + `modeValue`, refreshed live on `framework-edit-mode:changed`.
- **Submission is native Turbo** — the cloned form sits inside the entity's Turbo
  Frame, so the response swaps the frame exactly as before. `submitted`
  dispatches `suggestion:submitted` on success; `frameRendered` re-opens the
  editor when the response carries `data-editor-error` (seeded with the attempted
  value); `frameMissing` / `fetchError` claim transport failures and show a
  retry message inside the still-open editor rather than letting Turbo render
  "Content missing" over the user's work.
- **Dirty flag** — stamps `data-editor-dirty="true"` on the root; `matrix#refresh`
  / `updateSelection` / `updateSearch` confirm before re-fetching the matrix out
  from under an open editor.

**Reused outside the explorer.** The calibration session page's name pencil
(`Views::CalibrationSessions::SessionNameFrame`) rides the same editor. Mount
`field-editor` and a `FieldEditorTemplate` on an element *around* the host's
Turbo Frame, with the `turbo:frame-render` / `frame-missing` /
`fetch-request-error` actions: those events fire on the frame and bubble up, so
a controller mounted inside the frame never hears the 422 re-render it needs to
re-open the editor.

`inline_editor_controller.js` (the old per-element display/form toggle) stays in
place **only** for the non-explorer hosts that use `<select>` / `<input type=date>`
rather than a textarea — the assessment-cycle settings frames. Don't add new
explorer callers to it.

### explorer_menu_controller.js (edit mode only) — ONE menu for the whole grid
Mounted **once** on the explorer root; every ⋮ in the matrix ships as a bare
`<button data-action="explorer-menu#toggle" data-menu="<kind>" data-menu-*="…">`
and the menu is built on open from that dataset plus the grid's own coordinates
(§11a). Kinds: `capability` · `expectation` · `illustration` · `category` ·
`expectation-create` · `illustration-create`, each with a builder function in the
controller. Owns the open/close lifecycle (Esc → focus back to trigger, outside
click, `modal:open`, acting on an item), fixed positioning that follows the
trigger on scroll, roving ArrowUp/Down/Home/End focus, and the **resolved-
suggestion memory** that renders a later-built Approve/Reject pair terminal
(§12). It builds nothing itself that behaves — items carry the `data-*` for
`modal#open` / `field-editor#open` / `reorder-move#move` / `reorder-list#moveUp`
/ `suggestion-action#approve`, which mount on the one open menu.

### reorder_move_controller.js (edit mode only)
The Move up / Move down menu items. POSTs the neighbour-relative move, lets
`@rails/request.js` render the response's toast stream, then **repositions the
node(s) in place**: a capability's compact `<tr>` plus its expanded `<tr>`
(which must stay adjacent — the accordion pairs them by capability id), or a
category's whole `<tbody>`. It used to answer nothing but `org-structure:updated`
→ `matrix#refresh`, re-fetching ~950 KB of matrix — and every loaded expanded
row with it — to change the order of two rows. A 422 answers its own stream
(request.js only auto-renders OK responses), so a refusal still reaches the
user. See §11b.

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
[assessments' Stimulus-controller table](../assessments/stimulus-controllers.md), where it was
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

### archive_illustration_form_controller.js (edit mode only)
Prefills the shared archive-illustration modal from the illustration kebab's
"Archive…" item (id + a short excerpt for the confirm sentence) and clears any
reason left over from a previous open. The modal replaced the menu's native
`confirm()` — see §11b.

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
| `framework-edit-mode:changed` | `edit_mode_toggle_controller` | `{ mode: "editing" \| "suggesting" }` — the open editor's Save/Propose label + amber tint update immediately (`field-editor#modeChanged`). |
| `suggestion:submitted` | `field_editor_controller` | `{ formAction: string }` — fired on successful `turbo:submit-end`. Triggers `context_pane_controller#onSuggestionSubmitted`, which forces the panel frame to reload so a just-landed pending row appears without a page refresh. |
| `suggestion:open-card` | `matrix_controller#openSuggestionCard` (squiggle / ghost click) | `{ suggestionId: string }` — opens that suggestion's card in the pane (`context_pane_controller#onOpenSuggestionCard`) and reveals a collapsed pane (`framework_explorer_controller#openContextPane`). The click's purpose IS to see the card, so this is the one deliberate exception to "focus never auto-opens the pane" (Lesson 8 still governs plain focus changes). |
| `suggestion:resolved` | `suggestion_action_controller` (approve) / `reject_suggestion_form_controller` (reject) | `{ suggestionId: string, outcome: "approved" \| "rejected", surgical: boolean }` — fired on a successful inline approve/reject (the clarification-resolve dispatch carries no detail; consumers must tolerate its absence). `surgical: true` means the response's Turbo Stream already replaced the affected frame — `matrix_controller#refresh` skips the full re-fetch and only runs as the fallback for non-surgical shapes (Hard-Won Lesson 23). The feed reloads separately via the activity broadcast (§12, Hard-Won Lesson 21). |
