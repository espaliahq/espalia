# Framework Explorer — Suggestions and the Context Pane

> Part of the [framework-explorer.md](../framework-explorer.md) guide set. Read this when: changing the context pane, the activity feed, pending-change decoration on the grid, inline approve / reject, clarifications or suggestion threads (§8–§10, §12–§13).

## Key Design Decisions

### 8. Focus Context (Context Pane)

**Edit mode only.** The context pane does not render in view mode — viewers see no **Activity** toggle and no right-hand pane. View mode is "published state, clean"; collaborative chatter lives behind `/edit`.

The right-hand context pane keeps the Turbo Frame id `#suggestion-panel` (the focus protocol and every `data-turbo-frame` target predate the feed and still name it), but what it renders is the **activity feed** — `Views::Frameworks::Activity::PanelFrame`, swapped for `Activity::SuggestionCardFrame` at suggestion focus. `Suggestions::PanelFrame` and `FocusedSuggestionsQuery` now serve only the suggestions index's panel response (`GET /frameworks/:id/suggestions?layout=panel`) — the pane's own frame carries `layout=panel` too, so the **path** is what tells the two apart, not the param. See [*Activity feed coverage*](../framework-explorer.md) and §9.

It narrows its contents to the currently focused scope. There are four focus levels, each narrower than the previous:

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

**Panel header is focus-driven**: `ActivityFeedQuery#descriptor` renders the focus title ("All framework activity" / "`<Category>` — category" / capability / "`<Capability>` × L`<n>`") and the server-rendered `clear_path` powers both the × on the breadcrumb and the worded "← Show all framework activity" link. A top-right "All suggestions" link breaks out of the frame (`data-turbo-frame="_top"`) to the standalone review index. The row-presentation principles are in §9.

**Focus is visible on the grid, and legible + clearable in one place (#382).**
Three separate gestures set focus and others clear it, so neither half can be
left implicit:

- **On the grid**: `matrix_controller#applyGridFocus` stamps `data-focused` on
  the focused compact row, its level cells and the focused category band; the
  ring is CSS hanging off that attribute (`.mx-row[data-focused]` and friends in
  `application.css`), so a client-side-only state costs the grid no bytes. It is
  diffed against the previously-stamped set and re-applied after a frame load,
  since the swap discards the attributes with the nodes that carried them. A
  cell's ring is `outline`, not `box-shadow`, so it composes with the row's
  inset lines rather than replacing them — and the focused sticky capability
  cell's rule carries the column's right-edge shadow too, since that is the same
  property.
- **In the pane**: the header renders the focus chain as a breadcrumb
  ("`Thinking › Strategic Thinking › L2`") with an **×** beside it — the same
  clear path as the worded link (`context-pane#clearFocus` →
  `suggestion:navigate { level: "framework" }`). `ActivityFeedQuery#descriptor`
  therefore carries `category_name` at capability and cell focus too, which the
  title alone never showed. While nothing is focused the breadcrumb's line is
  given over to a one-liner naming the three gestures — on screen exactly while
  it is actionable.

**Single-scope accordion**: at most one focus scope is active. Focusing a new row clears any prior cell focus. Collapsing a row clears cell focus.

**Role filter layering**: role selection always applies, but only to `role_illustration` rows in the panel. Higher-level entity types (capability, category, expectation) are unaffected by the roles filter — those are framework-level constructs.

**Server-side filtering**: `Frameworks::FocusedSuggestionsQuery` walks eager-loaded framework associations once and builds in-memory `Set`s of in-scope IDs (category / capability / expectation / illustration). No denormalized columns or migrations on `framework_suggested_edits`. The framework read model is small enough (100-200 capabilities) that in-memory resolution is cheap.

**Pane default visibility**: in edit mode the pane is open by default **on desktop** — contributors are usually here *because* of the suggestion feed. **Below `lg` it is a slide-over that starts closed** (§7): there it would otherwise take 320 of a 375 px viewport. Within edit mode, focus actions still never auto-close or re-open the pane; the user can collapse it with the "Activity" toggle and it stays collapsed until they reopen. The no-auto-open rule remains valid inside the mode (focus is an invisible background state until visible); it no longer needs to justify a closed default on desktop. **One deliberate exception on every viewport**: clicking a pending-change squiggle, a ghost, or a clarification glyph opens that suggestion's card via `suggestion:open-card`, and `framework-explorer#openContextPane` reveals a closed pane to show it — on a phone that means the slide-over opens. The click's whole purpose is to see the card; ordinary focus changes (row expand, category or cell click) still never open the pane (see the event contract).

### 9. Suggestion Row Presentation

Each suggestion row must answer three questions at a glance: **what kind of entity**, **what action**, and **where in the framework**. Internal categorisations (review tiers, entity type codes) are never shown — they serve the system, not the user.

> **Which surface this describes.** The *principles* below govern every place a suggestion is listed, the pane's activity feed included. The *mechanics* — `Suggestions::PanelFrame#header`, `FocusedSuggestionsQuery` — belong to the **suggestions index's panel response** (`GET /frameworks/:id/suggestions?layout=panel`, i.e. `SuggestionsController#render_panel`), the only caller left since the context pane became the activity feed. Grep by that path, not by `layout=panel`: the activity frame sends the same param. The pane's own header is §8's; its entries are `Views::Frameworks::Activity::Entry`, whose kinds, groups and anchors are covered under [*Activity feed coverage*](../framework-explorer.md).

**Panel header** (rendered by `Suggestions::PanelFrame#header`):
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
| `ExpandedRow` → `IllustrationFrame` | Illustration text (expanded row, fetched on demand) | `cell_data[:illustration_pending_edits][illustration_id]` | `cell_data[:illustration_pending_edit_details][illustration_id]` |

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

**Inline editor seeds with the pending proposal.** When a field has a pending edit, the host's `data-editor-value` carries the **proposed** value (not the persisted one), so opening the editor refines the proposal that's already shown as the diff — see the shared `inline_editable.rb#inline_editor_value(current_value, pending_edit)` helper, used by every inline-edit frame (capability name + description, category name, expectation text, illustration). Cancel discards the cloned form entirely, so re-opening returns to the proposal too.

### 12. Actionable feed entries (inline suggestion review) — the recurring pattern

The activity feed is not just a narrative log — a **pending suggestion's
submission entry is *actionable*** for a reviewer who can clear its tier. This is
the canonical instance of a reusable **"actionable feed entry"** pattern: an
entry that both narrates *and* offers the action inline, with a modal escape
hatch for the cases that need input. The same pattern applies to the assessment
feed (see [assessments.md](../assessments.md)) and to future suggestion entity
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
   so `matrix#refresh` knows whether to skip. This fallback and the
   header-changing org-structure edits are now the ONLY things that re-fetch
   the matrix (§11b) — every other write streams its own rows. The **feed**
   then reloads off
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
kebabs — every one of them a **bare trigger** that
`explorer_menu_controller.js` turns into a menu on open (§11a), fed by
`Views::Frameworks::Explorer::Concerns::MenuItems#approval_menu_data`:

- **Matrix row-actions kebab** (`MatrixRow`) — when a capability has a pending
  name / description edit the viewer can approve, the trigger carries that
  suggestion's id and the menu gains **Approve / Reject «field» change** items
  (alongside **Archive…**, offered to any suggest-rights viewer — see §11).
- **Expectation cell kebab** (`MatrixCell`) — the ⋮ of every expectation cell in
  edit mode; the Approve/Reject pair appears when the cell carries a pending
  edit and the viewer clears the expectation tier. Rendered OUTSIDE
  `ExpectationTextFrame` so the inline-edit frame swap can't drop it (no
  controller re-threading needed).
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
carry the same kebab — "Approve/Reject new example/expectation" — so a
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
`MatrixCategoryGroup` → `MatrixRow` → `MatrixCell`, and — because the expanded
row is a separate on-demand response (Lesson 25) — controller →
`ExpandedRow` → `IllustrationFrame` via `FrameworksController#viewer_matrix_flags`,
the one definition all three matrix renders splat.
`matrix#toggleRow` ignores clicks on any `button`/`form`/`[role='menu']`, so
opening a kebab — or acting in its menu — never expands the row.

**Resolution memory lives on the controller, not on a mounted kebab.** A menu
that no longer exists can't be marked terminal, so `explorer-menu` keeps the
set of resolved suggestion ids it has seen (from `suggestion:resolved@window`)
and renders their Approve/Reject items disabled + "✓ Approved" when a menu is
built *later* — the same guarantee the per-kebab `suggestion-action` mount used
to give a menu already in the DOM (Hard-Won Lesson 23).

### 12a. Suggestions are anchored discussions — the clarification kind

A **suggestion is an anchored, lifecycled discussion**, of which *proposals*
(edit / create / delete — the kinds applied on approval) are the applying
subset. This framing became explicit with the fourth kind, **`clarification`**
(born from calibration sessions — see
[calibration-sessions.md](../../architecture/calibration-sessions.md)): a
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
