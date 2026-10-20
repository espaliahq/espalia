# Framework Explorer — Hard-Won Lessons

> Part of the [framework-explorer.md](../framework-explorer.md) guide set. Read this when: a lesson in the core guide's index names what you are about to touch. The numbers are cited from code comments and other guides; never renumber.

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

### 21. A write answers a Turbo Stream or a 204 — never a bare 200, never a redirect

Learned on the "actionable feed entry" wiring and since generalised to every
edit-mode write (§11b):

- **A stream or a 204, never an empty 200.** A Turbo form submit (the reject
  modal) that gets a `200` with an empty body makes Turbo Drive render the
  empty body — **blanking the page**. The inline resolution response is either
  a turbo-stream (processed in place, no navigation) or `head :no_content`
  (Turbo does nothing: the modal closes via `turbo:submit-end` and the page is
  untouched). (The approve path uses `@rails/request.js`, which doesn't
  navigate regardless.)
- **Never a redirect either.** A redirect is a full page load of a
  multi-megabyte explorer, and it costs the user their scroll position and
  every expanded row they had opened — for an action as small as archiving one
  row. That applies to *failures* too: a refused write answers 422 + the toast
  stream, not a redirect with a flash.
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
me&u framework that frame measured **7,615,168 B of HTML with 3,338 Stimulus
controller mounts, 3,206 forms and 2,356 textareas** (every cell pre-rendered
its hidden inline-edit form — the baseline row of the table below) — each swap costs seconds of main-thread parse +
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

**Most of that frame is gone.** The 2026-09-07 edit-mode review turned into a
run of changes that each took a bite out of it. All figures are
`GET /frameworks/<me&u>/edit/matrix?track=both`, signed in, on the seeded me&u
framework (~38 capabilities, 11 roles × 8 levels, ~995 illustrations) — but
each row was measured against **its own merge-base**, so they describe steps,
not a single arithmetic chain:

| Step | What it removed | Edit-matrix frame |
|---|---|---|
| baseline (pre-#378) | — | **7,615,168 B** (gzip 311 KB) · 3,338 controller mounts · 3,206 `<form>` · 2,356 `<textarea>` · 888 `Kit::Dropdown` · 50,146 DOM nodes; one role toggle ≈8 s click→idle |
| [#378](https://github.com/mr-yum/growth-os/pull/386) — expanded rows fetched on demand (Lesson 25) | the hidden expanded rows: **81%** of the payload | 1,460,574 B (gzip 95 KB) · 485 mounts · ≈1.2 s |
| [#379](https://github.com/mr-yum/growth-os/pull/387) — one shared inline editor (Lessons 26–28) | 374 `<form>` + 374 `<textarea>` + their mounts | 1,222,619 B · 111 mounts |
| [#380](https://github.com/mr-yum/growth-os/pull/388) — delegated kebabs, one hover cluster, an icon sprite (Lessons 29–31) | 38 dropdowns, 758 inline `<svg>` glyph definitions | ≈947,000 B · **0 mounts** |
| [#381](https://github.com/mr-yum/growth-os/pull/389) — one write-response contract (§11b) | full-page reloads and whole-matrix re-fetches per write | frame unchanged; a write costs ~11 KB of stream instead of a 1,161,871 B reload |
| [#383](https://github.com/mr-yum/growth-os/pull/393) — one fetch per burst, a 304 for a repeat, component classes (Lesson 33) | 52% of the `class` bytes; 4 of every 5 fetches in a filter burst | **907,516 B**, **54,656 B gzipped** · a repeat filter state is a 304 |

End to end: **7.6 MB → 907 KB uncompressed, 311 KB → 55 KB on the wire, 3,338
Stimulus mounts → 0.** ([#382](https://github.com/mr-yum/growth-os/pull/398)
and [#384](https://github.com/mr-yum/growth-os/pull/400) close the same review
set — measured sticky offsets / on-grid focus, and the phone layout — and
change no payload.)

The remaining bulk is the content itself plus the shared editor's per-host
`data-editor-*` contract (~175 KB), which buys the zero pre-rendered forms and
has no cheaper form. Even so, treat "re-fetch the matrix" as a last resort in
any new explorer feature: ~900 KB of HTML per approval is still the wrong
shape, and the surgical streams exist so it never has to happen.
`test/performance/explorer_payload_test.rb` now fails when any of this grows
back.

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

### 25. The expanded rows are fetched on demand — never render them into the matrix

Measured on the real me&u framework (36 capabilities, 997 illustrations, all
roles): the hidden expanded rows were **81% of the edit-mode matrix** (6.2 of
7.6 MB — 850 example frames and 1,131 "+ Add example" frames, each
with its own form and Stimulus mount) and 79% of view mode's 1.3 MB, for rows
the accordion shows one at a time. One role-checkbox toggle cost ~7 s of
client time parsing and mounting all of it.

So `MatrixRow#expanded_row` renders only a placeholder `<tr>`
(`Views::Frameworks::Explorer::ExpandedRow` with `loaded: false`): the
accordion's target/data attributes, one loading cell (with the shared
`Shared::FrameLoadError` block for failures), and `data-expanded-src` — the
mode-specific `expanded_row` / `edit_expanded_row` path. The role/track scope
rides ONCE on the `<table>` (`data-expanded-row-scope`), not once per row: at
100 roles × 150 capabilities a per-row copy is ~700 KB of attribute text.
`matrix_controller#ensureExpandedRowLoaded` fetches it on first expand and
swaps the `<tr>` (parsed through a `<template>`, which is what makes a bare
`<tr>` string parse as a row). A `<turbo-frame>` can't do this job: the HTML
parser foster-parents a custom element out of a `<tbody>`, and a frame inside
one spanning `<td>` can't yield the per-column cells. Rules that fall out:

- **Anything that looks inside an expanded row must await `#expandRow`** —
  it resolves with the loaded row. Feed navigation to a pending illustration's
  squiggle, cell-level navigation (`td[data-level-ordinal]`), and any future
  "scroll to X inside the row" go through it. A synchronous
  `expandedRowTargets.find(...).querySelector(...)` sees the placeholder.
- **The loaded row keeps whatever `hidden` state the placeholder has at swap
  time** — a user can collapse (or re-expand) while the fetch is in flight, and
  the swap happens in the same task as the state check so no frame paints
  between them.
- **The in-flight promise lives on the placeholder element, not the
  controller.** The `matrix` controller sits outside the matrix frame and
  survives frame reloads; a capability-keyed cache would hand a fresh
  placeholder (same capability, new node after a role toggle) a promise that
  resolves by swapping a node no longer in the document — "Loading examples…"
  forever. Same reason `connect()` re-fetches any placeholder a Turbo cache
  restore brought back open, and `navigateToEntity` checks a navigation token
  after the await so a slow earlier click can't scroll back over a later one.
- **Cell focus is decided from the compact row.** Only a focusable compact
  cell (expectation + selected bound role) carries `data-level-ordinal`, so
  feed navigation settles focus + URL synchronously and only the scroll waits
  for the row; `expand_matrix_row` in system tests waits for the loaded row by
  default (`await_content: false` when the load is under test).
- **The endpoint runs the same `MatrixDataBuilder`** as the matrix (in-memory,
  ~7 ms) and picks the capability out, so the loaded row cannot drift from the
  compact row it sits under; a capability outside the current scope is a 404,
  which the client renders as the placeholder's error state (never inserted
  into the table — the parser guard rejects anything that isn't the expected
  `<tr>`, a sign-in page included).
- **Surgical resolution streams targeting `illustration-*` /
  `pending-suggestion-*` frames only find a target when the row is open** —
  the correct outcome; a closed row fetches fresh on its next expand. The
  illustration-create stream appends to a `<ul>` that exists only in a loaded
  row, which is the only place the form can be submitted from.
- **The row's content is still heavy** (~450 KB for one capability across 11
  roles in edit mode) because of the per-illustration forms and kebabs —
  #379 / #380 shrink that next.

Pinned by `test/system/frameworks/lazy_expanded_row_system_test.rb` and the
`expanded_rows` contexts in `test/controllers/frameworks_controller_test.rb`.

### 26. A bodyless 4xx inside a Turbo Frame is a silent failure

`FrameController#loadResponse` renders whatever comes back — success or error —
but only `if (html)`: a `head :unprocessable_content` has no body, so Turbo does
**nothing**. The four inline-edit endpoints answered exactly that, and the user
clicked Save and watched nothing happen; a blank value, a stale entity, a policy
denial and a 500 were indistinguishable.

An error response from a frame-scoped submit must therefore **carry the frame**:
re-render the same `turbo_frame_tag` with the message inline and status 422.
Two things fall out of that:

- **Echo the attempted value back.** Rendering the frame destroys whatever
  editor was inside it, so the response has to carry the user's text
  (`attempted_value:` → `data-editor-value`) or the swap eats their typing. The
  shared editor re-opens on any host carrying `data-editor-error`, seeded from it.
- **The re-render is async and NOT awaited before `turbo:submit-end`.** Hang the
  re-open on `turbo:frame-render`, never on the submit-end handler — verified in
  turbo-rails 2.0.23, where `formSubmissionFailedWithResponse` calls
  `loadResponse` without awaiting it.

A `submit-fallback` controller is deliberately NOT mounted on the explorer root
for this: its `beforeFetchResponse` claims every non-stream error response with
`preventDefault()`, which would swallow exactly these 422 frame renders. The
editor handles its own transport failures instead (`turbo:frame-missing` /
`turbo:fetch-request-error`), which is also the only place that can keep the
open editor and its text.

### 27. An editor inside an auto-layout table can only be as wide as its host already is

The old inline-edit form was a fixed `w-80 sm:w-96`; opening one in a level
column widened the matrix to 1,922 px and pushed later levels off-screen. The
obvious replacement — `w-full min-w-0` — is wrong in two opposite ways at once,
and understanding why is the whole lesson:

- **A percentage width doesn't render wide.** Inside a `<td>` whose width is
  still being negotiated, Chrome resolves `width: 100%` as shrink-to-fit, so the
  editor collapsed to roughly its own Save/Cancel buttons (~110 px) instead of
  filling the cell.
- **But everything else you add DOES widen the column.** `table-layout: auto`
  negotiates each column from its content's *intrinsic* width, so any definite
  width, and any text with a wide min-content, leaks straight through. Three
  measured dead ends: a visible "Applies immediately / Lands as a suggestion for
  review" hint in the button row (+18 px per column — it is now `sr-only`);
  pinning the form to the **cell's** inner width (+108 px, because the form's px
  width is added to whatever else shares its flex row); and flooring the pinned
  width at a "comfortable" 144 px (+20 px on a squeezed mobile table, where the
  floor becomes the column's new min-content).

What works is pinning the form to the **host's own pre-open width**
(`#pinWidth`): the host already occupied exactly that much, so the negotiation
is unchanged at every viewport, and a block-level host (an expectation cell, a
description, an illustration) hands the editor the full cell. A shrink-to-fit
host (a capability name, a level title) gets a narrower editor — accepted, since
the alternative is moving the column. `LevelTitleFrame` documents the one place
this was tried and reverted.

The general rule: inside a matrix cell, **any text or definite width you add to
an editor is a column-width change**. Put explanatory copy in `sr-only`, a
`title`, or the button label. Pinned by
`test/system/frameworks/org_structure_rename_system_test.rb` ("not widen the
level column when the editor opens") and the mobile case in
`inline_editor_system_test.rb`.

### 28. Turbo's submit-end can beat its own frame render — don't drop state on it

Three of the shared editor's handlers hang on Turbo's ordering, and the
intuitive reading is wrong. In turbo-rails 2.0.23 `formSubmissionFailedWith
Response` / `…SucceededWithResponse` call `loadResponse` **un-awaited**, while
`turbo:submit-end` is dispatched from `FetchRequest#perform`'s `finally`. So
`turbo:submit-end` fires *before* the frame has rendered, and before any
`turbo:frame-missing` the response provokes.

Consequences the editor has to live with:

- **Never release ownership of the form in `submitted()` on failure.** Doing so
  disarmed `frameMissing` (so a 5xx or a sign-in redirect rendered Turbo's
  "Content missing" over the user's text after all) and, on a network drop,
  stranded a form the controller no longer knew about — visible on screen,
  Cancel a no-op, and a second pencil click appended a *second* editor.
- **Re-open after a rejected save on `turbo:frame-render`, not `submit-end`** —
  at submit-end the error frame isn't in the DOM yet.
- **Arm transport handlers explicitly.** `turbo:frame-missing` is dispatched on
  the frame for *any* load, so claiming it by "does this frame contain my form"
  also swallowed the matrix's and the expanded row's own failure handling
  (Lesson 25's sign-in-redirect recovery). Track the submitting form from
  `turbo:submit-start` and match on identity — the same shape
  `frame_error_controller` already uses.

### 29. Delegating a widget is only a win if the trigger stays small

The first cut of the delegated kebab (#380) shipped each trigger's whole menu as
a JSON `data-menu-items` blob — labels, URLs, modal ids, the lot. It removed
every `Kit::Dropdown` mount as intended and made the matrix **bigger**:
1,081,634 → 1,435,013 B. Two reasons, both worth remembering:

- **An attribute is HTML-escaped, so JSON is expensive there.** Every `"` in the
  payload renders as `&quot;` — six bytes for one. A blob with a hundred quotes
  costs 600 bytes of escaping alone, and it repeats per trigger.
- **A delegated widget invites more instances.** Making the cell kebab
  unconditional (so a touch user has one control per cell — §11a) went from 38
  triggers to 330. A per-trigger payload that was tolerable at 38 is the whole
  budget at 330.

The shape that works: the trigger carries **ids and permission flags only**, the
controller holds the labels and composes the items, and anything already on the
grid is read rather than repeated (`tr[data-capability-name]` feeds every cell's
Discuss context label). Two more levers fell out once the triggers multiplied:

- **Repeated chrome belongs in CSS, not in a class attribute.** The kebab's
  utility string was ~200 bytes × 330, the pencil's ~160 × 374. `.explorer-kebab`
  / `.explorer-cluster-btn` / `.explorer-menu-item` / `.explorer-add` are plain
  CSS for the same reason the hover-cluster rule is: they repeat thousands of
  times, and utilities are paid for per element.
- **The same goes for icons.** A `<use href="#icon-pencil">` is ~55 bytes
  whatever the glyph costs to define — 218 KB of inline paths became ~103 KB of
  references *while the icon count grew*.

Final: **1,222,619 → 946,778 B (−22.6%)** on the matrix, 111 → 0 controller
mounts; one expanded row **362,526 → 228,000 B (−37%)**, 70 → 0 mounts.

### 30. A fixed menu should follow its trigger, not dismiss on scroll

`Kit::Dropdown`'s fixed strategy closes on any scroll, because a `position:
fixed` panel otherwise detaches from the trigger it belongs to. Carrying that
rule into the delegated menu made it flaky in a way that looked like a dropped
click: a JS-dispatched `scrollIntoView` immediately before the trigger click
queues a scroll event that lands *after* the menu opens, closing it in the same
turn. Repositioning on scroll instead is both cheaper to reason about and
better behaviour — the menu tracks its trigger, and the only close-on-scroll
case left is the honest one (the menu's own node was replaced by a surgical
Turbo Stream, so `isConnected` is false).

The related placement rule: **insert the menu next to its trigger, not at the
explorer root.** `position: fixed` escapes the matrix's scroll clipping either
way, but a menu item still has to reach its entity — `field-editor#open`
resolves its host with `closest("[data-editor-action]")` and `reorder-list`
with `closest("[data-reorder-item-id]")`. A root-mounted menu breaks both.

### 31. `position: fixed` escapes clipping, not paint order

The delegated kebab menu is `position: fixed`, which was supposed to settle
where it renders: no overflow ancestor can clip it. It still came out **under
the row below it** — the last two items of a capability menu were painted over
by the next row's cells.

`fixed` takes an element out of flow and out of its ancestors' *clipping*, but
it still composites inside the nearest ancestor that creates a **stacking
context**. The matrix's sticky capability column is `position: sticky;
z-index: 2`, so the menu — however high its own `z-50` — could only ever paint
at z-index 2 among that column's siblings, and the equally-ranked sticky cell
of the NEXT row wins on document order.

Two fixes were available and the cheaper one is wrong here: portalling the menu
to `document.body` removes every ancestor, but the menu's items resolve their
entity by `closest(…)` (`field-editor#open` → `[data-editor-action]`,
`reorder-list#moveUp` → `[data-reorder-item-id]`, and Stimulus binds
`reorder-list` actions by ancestry at all), so a portalled menu would need every
one of those re-plumbed. Instead the controller **lifts the offending ancestor**
while the menu is open (`LIFTED_Z = 9`) and restores its inline `z-index` on
close — chosen to clear the grid's body cells (z-2) and category headers (z-5)
while staying under the sticky column headers (z-10) and corner (z-20).

Two things to carry forward:

- **When an overlay renders "behind" something, look for a z-indexed positioned
  ancestor before touching the overlay's own z-index.** Raising `z-50` to
  `z-9999` would have changed nothing.
- **A paint-order test must probe where the overlap actually is.** The first
  version sampled the centre of the menu's last item — which overhangs into the
  non-positioned level columns, where the bug does not exist — and passed
  happily against the broken build. The test now computes the intersection with
  a later sticky cell and fails loudly if the fixture produces none, so it can
  never pass vacuously (testing.md's "an assertion a dropped click would also
  satisfy is not a test").

### 32. A `<template>` parses table fragments; `<div>`-wrapping them does not

Turbo Streams insert their payload by cloning a `<template>`, and the HTML
parser has an "in template" insertion mode that switches to "in table" /
"in row" for `tbody`/`tr`/`td` — so `<tr>` and `<td>` fragments survive a
stream verbatim. That is what lets the write-response contract (§11b) address
the grid at its natural grain instead of re-rendering whole regions.

Two things that follow, both easy to get wrong:

- **The anchor has to be an element the fragment can target.** A capability
  had no id on its compact `<tr>` and a category had no wrapper at all, so the
  only addressable thing was the matrix frame — which is why every structural
  write used to redirect or refresh. Giving each category its own `<tbody>`
  costs nothing (it is valid HTML, and `matrix#toggleCategory` walks siblings,
  which now simply stop at the tbody boundary) and turns a contiguous block of
  rows into one node a stream can remove and a controller can move.
- **Insert against a row that is always present.** A new capability is
  inserted `before` its category's "+ Add capability" row rather than
  `append`-ed to the group, because the group's last row is what "the end of
  this category" actually means on screen. That row exists for exactly the
  viewers who can add a capability, so the anchor is never missing when it is
  needed.

### 33. A utility string is paid for per element; a class name once

After #378/#379/#380 the single biggest attribute left in the edit-mode matrix
frame was `class` — 234,518 B, 23% of it, with ~190 KB in **twenty** strings the
grid repeats hundreds to thousands of times (`px-3 py-2.5 border-b border-r …`
on 282 cells, the sticky column's two arbitrary-value shadows on ~100, the
expectation paragraph's text tokens on 282). Moving them into component classes
in `app/assets/tailwind/application.css` — the treatment #380 gave
`.explorer-kebab` / `.explorer-add` — took class bytes to 111,682 (**−52%**) and
the frame to 907,516 B.

Three rules for anything added there:

- **These rules sit OUTSIDE Tailwind's layers, so they beat a utility for the
  same property.** Never pair a component class with a utility that sets a
  property it declares — put the variant in the class, or leave the whole thing
  a utility.
- **Sticky-cell backgrounds deliberately stay utilities.** The opacity guard in
  `matrix_sticky_column_system_test.rb` scans the class list it was written
  against (Lesson 24); moving `bg-*` into CSS would make that scan report a
  clean grid it could no longer see. The geometry and the edge shadow moved;
  the backgrounds did not.
- **A glyph can be sized by the control that holds it.** `.explorer-kebab > svg`
  and friends removed `w-4 h-4` from 340 kebabs and `w-3.5 h-3.5` from 282
  Discuss bubbles; the call sites pass no class at all (`icon("kebab")`), so
  there is nothing to keep in step. Same trick for the inline editor's
  positioning context: `[data-editor-action] { position: relative }` reuses the
  host contract instead of a `relative` on 282 elements.

The names are literals at their call sites, so the JIT is not involved and
Lesson 12 (no interpolated class names) is unaffected.

### 34. A cache key must move when the code does, and at sub-second precision

Two things the explorer's conditional GET (#383) got wrong before it got them
right, both silent:

- **A deploy changes the markup without changing any data.** An ETag derived
  purely from the graph snapshot and the filter axes is identical across
  releases, so the browser keeps rendering the *previous* release's grid until
  something in the framework happens to change. The running release is in the
  key (`config.x.release_id` — `RENDER_GIT_COMMIT`, else a per-process token,
  which costs a cross-worker cache miss rather than a stale hit).
- **`ActiveSupport::Cache.expand_cache_key` stringifies a `Time` to whole
  seconds.** Two edits inside the same second therefore produced the same key,
  and the second one was answered with a stale 304 — caught only because a test
  edited a capability immediately after reading the matrix. Every timestamp in
  a key goes in at nanosecond precision (`utc.to_fs(:nsec)`), the way
  ActiveRecord's own `cache_version` does it.

A third, benign, surprise while testing it: **Rails mixes the flash into every
ETag** (`ActionController::EtagWithFlash`), so a request still carrying a
sign-in notice keys differently from the identical one after it. Integration
tests must land on the redirect before measuring.

### 35. Turbo re-fetches a same-value `src`, so "skip when unchanged" disables refresh

The filter debounce (#383) shipped with a guard that skipped assigning the
frame's `src` when it already held that value — on the premise that Turbo
would no-op the assignment and leave the busy bar up forever. The premise is
wrong twice over:

- `FrameElement`'s `src` setter calls `setAttribute`, and a custom element's
  `attributeChangedCallback` fires for **any** `setAttribute`, same value or
  not. Turbo's handler then runs `sourceURLChanged()`, which clears `complete`
  and loads. A same-value assignment is a real fetch.
- And `matrix#refresh` — the §12 non-surgical fallback, and the org-structure
  edits that change the matrix header — exists precisely to re-fetch with the
  axes it already has, so it *always* computes the src the frame is holding.

Net effect: the first refresh worked (the frame starts with no `src`), Turbo
then wrote the response URL into `src`, and **every later refresh silently did
nothing** — a second approval left the acting user looking at the resolved
suggestion's stale inline diff. Nothing failed, because the existing coverage
refreshed once per test on a fresh page.

Two things to carry forward: a "nothing changed, skip the work" guard on a
Turbo Frame needs the *frame's* semantics checked, not assumed; and a repeat
fetch of an unchanged state is a 304 now, so there was nothing to save anyway.
Pinned by `matrix_refetch_system_test.rb` ("re-fetch every time it fires").

### 36. A sticky child moves; its parent's rect does not

The sticky-offset work (#382) needed one number — where the matrix header's
bottom edge actually is — and `thead.getBoundingClientRect().bottom` is the
obvious way to ask. It is wrong, silently and only once the grid is scrolled:
stickiness lives on the `<th>`s, and an ancestor's rect is computed from its
own normal-flow position. Scrolled a few hundred pixels, the `<thead>` reported
a bottom **above the top of the viewport** while its stuck cells sat exactly
where the eye put them. Height is unaffected, so a measurement that only wants
the height looks fine and one that wants a position quietly does not.

Two things fell out of it:

- **Ask the element that carries `position: sticky`.** `thead th` for the
  header; the category band's own `<tr>` (which IS the sticky box) reports
  correctly and needs no special case.
- **A geometry test can pass for the wrong reason.** The first version of
  `matrix_sticky_offsets_system_test.rb` expanded the LAST row — which
  `scrollIntoView({ block: "start" })` cannot lift to the top, because there is
  no content below it to scroll — so the row parked harmlessly mid-pane and the
  test passed against the very geometry it exists to catch. It now targets a
  middle row and asserts the grid was **not** at max scroll, so an arrangement
  that cannot exercise the bug fails loudly instead (testing.md's "an assertion
  a dropped click would also satisfy is not a test", in its geometric form).
  Verified the whole file bites by reverting the fix and watching all six row
  cases and all three band cases fail.

### 37. A closed `Kit::Dropdown` still matches `[role="menu"]`

Esc on a narrow viewport closes whichever pane is covering the grid, but must
stand down while a modal or an open menu owns it — so the guard asked
`document.querySelector("[role='menu']")`. It never let Esc through: a
`Kit::Dropdown` renders its menu **present and `hidden`**, and the role tree
ships one per role, so the selector matched on every edit-mode page and
disarmed the handler completely. `:not(.hidden)` is the whole fix, and it is
also why the delegated grid menus (§11a — built on open, removed on close) are
not the shape that bites: a widget that is *absent* when closed cannot be
mistaken for an open one.

The general rule: **"is one of these open?" is a question about state, not
presence.** Any guard written as a bare presence check has to be read against
how each matching widget represents "closed".

### 38. Selenium scrolls bottom-aligned before it acts, so a short scrollport puts a tall row back under the sticky header

`matrix_sticky_offsets_system_test.rb` deliberately ends in a REAL pointer
click on the row kebab — a JS dispatch cannot see the row sitting under the
sticky header, which is the bug it exists to catch (#382). It started failing
at 375 px the moment the explorer stopped guessing its height (#384): the
scrollport became the honest ~440 px of leftover viewport instead of a 620 px
box hanging below the fold, and an 11-role row no longer fits in it.

WebDriver "scrolls an element into view" **aligned to the bottom** of the
scrollport before a hover or a click. Hovering the tall `<tr>` therefore
dragged its top — where the kebab is — back up under the header, and the click
was intercepted by the sticky `<th>`. The geometry assertions just above it had
all passed; the scroll happened after them.

Two things to carry forward:

- **Selenium's pre-action scroll is test machinery, not user behaviour.** A real
  pointer hover scrolls nothing. Re-establish the resting position between the
  hover and the click.
- **Do it through the mechanism under test**, not with a raw offset:
  `scrollIntoView({ block: "start" })` honours the row's `scroll-margin-top`,
  which is the measured `--matrix-header-h` + `--matrix-category-h`. A wrong
  measurement still parks the kebab under the header and the test still fails,
  so the repair does not blunt it.


### 39. `pointer-events` inherits, so gating a cluster disarms the menu inside it

Floating the role tree's hover controls over the name (§11a) put an invisible
but still-hittable button on top of the text: on a coarse pointer at `lg` and
up — a touch laptop, where nothing reveals the cluster on approach — a tap on a
long name's tail fires `solo`. The obvious fix is to make `pointer-events`
track each control's reveal instead of the cluster's presence.

The obvious *implementation* of that fix breaks the kebab. `pointer-events`
inherits, and `Kit::Dropdown`'s menu is a DOM **descendant** of its trigger even
though `strategy: :fixed` paints it somewhere else entirely — so
`pointer-events: none` on the cluster's children reached the open menu and every
item in it. Visibly open, completely inert. Two things made it easy to miss:

- **A JS-dispatched click still opens it**, so every test that drives the menu
  that way passed. Only `edit_mode_system_test`'s `elementFromPoint` probe saw
  it — and that probe is not "is the menu on top?", it is "would a real click
  land on this item?", which an inert element fails for a completely different
  reason than the clipping it was written for.
- **The real gesture loses the hover it depends on.** The menu is positioned
  outside the row, so moving the pointer onto an item drops the row's `:hover`
  and re-disarms everything mid-gesture. Hovering the trigger to open it proves
  nothing about clicking an item.

So an open menu arms itself (`[role="menu"]`), and so does the trigger holding
it open (`[aria-expanded="true"]`, the same hook the shared cluster rule already
uses to keep an open kebab visible). The general rule: **when you gate
`pointer-events` on a container, enumerate the popups that live inside it** —
a fixed/absolute popup is not outside the subtree just because it is outside
the box.

### 40. Announce a draft from the event, not from each write

Removing a role binding through **Edit roles…** opens a draft, but the
binding editor answers only its own frame, so the header showed no draft and
no Publish button until a reload. An admin removed three bindings, saw them
applied in the editor, and never published; the assessments kept showing the
capabilities ([#496](https://github.com/mr-yum/growth-os/issues/496)). The
levels editor's add row, a shape-changing approval and every MCP write had the
same gap, and every *other* viewer's header was stale on all of them.

Streaming `draft_status_streams` from each write can't close that: it only
reaches the actor, and it needs every new write path to remember. The draft
opens exactly once, as `DraftVersionStarted`, so the projection broadcasts both
slots from there, mirroring the clear on `FrameworkVersionPublished`.

The Publish button is per-viewer, and a broadcast isn't. It goes out on its own
`framework_publishers` stream, which `ShowView` subscribes to only when
`can_publish`; Turbo signs stream names server-side, so nobody else can join
it. Two details matter:

- **Opens and clears go on the same stream.** ActionCable orders messages
  within a subscription, not across two, so a clear sent on the activity
  stream could land after the next draft's button and erase it.
- **Each message renders the current state, not "opened" or "cleared".**
  Messages from separate writes still race each other, so a clear from a
  publish could land after the next draft opened. Rendered from the
  framework as it stands at commit, a late clear shows that newer draft
  instead of blanking it.
- **Send after commit** (`ActiveRecord.after_all_transactions_commit`). A
  broadcast from inside a write that then rolls back would offer a Publish
  button for a draft that doesn't exist.

The subscription is decided at page load, so rights that change mid-session
take effect on the next load: someone who loses them keeps receiving the
button (the review page's policy still refuses them), and someone who gains
them sees the pill without it. The button shows "Publishing…" only for a
request against the open draft's own version (`FrameworkPublication.publishing?`);
the framework-wide `in_flight_for?` is the lock, and a previous version's
request that hasn't recorded its finish must not disable the next draft's
button.

The binding editor's system test had asserted `assert_text(/draft/i)` all
along, and it passed with the bug present: the activity feed's "Opened a
draft" entry satisfied it. Assert on the header slots themselves.
