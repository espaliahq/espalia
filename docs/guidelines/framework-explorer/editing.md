# Framework Explorer — Structural Editing

> Part of the [framework-explorer.md](../framework-explorer.md) guide set. Read this when: adding, archiving, reordering or renaming anything in edit mode, touching a kebab menu, the hover cluster or an add affordance, or changing what an edit-mode write responds with (§11–§11b).

## Key Design Decisions

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
  — the same inline-editor toggle as "+ Add example". Submits to
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
  migration mapping since illustrations carry no ratings. It opens the
  root-mounted `archive-illustration-modal`; the native `confirm()` the menu
  used to fire is gone — §11b.)*
- **Illustration kebab (⋮) → Move up / Move down** — in each illustration's ⋮
  menu in the expanded row (edit + `can_edit_structure`, list >1). Display-order
  only → **shape-preserving, applies live**. The `reorder-list` Stimulus
  controller (on the per-role
  `<ul>`) POSTs a neighbour-relative move (`{ illustration_id, target_id,
  placement }`) to `IllustrationReordersController`, which translates it into
  the complete ordered list for the shared
  `Operations::Frameworks::ReorderIllustrations` (web + MCP — the MCP tool
  takes the full list, no N-swap dance). On a 204 the controller moves the
  frame's DOM node in place — **no matrix refresh**, so the expanded row and
  scroll position survive; the menu closes with the click, so a second move
  re-opens the kebab (the trade for one reorder treatment everywhere — §11a);
  other viewers pick the order up on
  their next interaction (feed-live / matrix-not, Lesson 21). This was the
  first surface to move nodes rather than refresh; §11b generalises it. The
  Operation and the aggregate both refuse any list that isn't an exact permutation of
  that expectation × role's illustrations (a smuggled foreign id would
  silently renumber another expectation's list). Surfaces in the feed as
  `illustration_reordered` ("Reordered the E · Software Engineer
  illustrations", edits group).
- **Category kebab (⋮) → Move up / Move down** — in the category header's ⋮
  menu (edit + `can_edit_structure`; each direction
  only when a **visible** neighbour exists — role/search filters can hide
  categories, and a move is relative to what the viewer sees). Shape-
  preserving, applies live. Each item is a `reorder-move` button POSTing
  the neighbour-relative move to `CategoryReordersController`, which
  re-inserts the category next to that neighbour within the full active order
  and dispatches `Operations::Frameworks::ReorderCategories` (web + MCP,
  complete-list + permutation-validated like illustrations). The response is
  the toast stream and `reorder-move` **moves the category's `<tbody>` group
  in place** — a category is a contiguous *block* of rows, and one `<tbody>`
  per category is exactly what makes that block a single movable node (§11b).
  Graph + AR read models sort categories
  nil-ordinal-LAST with a stable tiebreak, so a category added after a
  reorder lands at the end instead of jumping to the front (which is also why
  an added category streams onto the **end** of the table). Feed:
  `category_reordered` ("Reordered the categories", structural group,
  framework-level anchor).
- **Row-actions kebab (⋮) → Move up / Move down** — reorder a capability
  within its category (edit + `can_edit_structure`; items appear only for a
  **movable** neighbour — struck pending-archive rows are skipped and get no
  move items themselves). Same machinery as the category items: a
  `reorder-move` POST to `CapabilityReordersController` → toast stream → the
  compact row and its expanded row move in place (§11b). The controller and
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
- **Category kebab (⋮) → Archive…** — in the same ⋮ next to the category **name**
  (not the far right of the full-width header, which scrolls off-screen on a
  matrix with many level columns), **only for an empty category** (the aggregate refuses to archive one
  that still holds active capabilities, so we don't offer it otherwise —
  `MatrixDataBuilder` computes `archivable` against the full, non-role-filtered
  capability set). Opens the archive-category modal — a plain confirm + optional
  reason, with **no migration mapping** (categories carry no ratings).
- **Draft pill** (`vN draft`, teal) + **Publish button** — header, edit-mode +
  draft-open only; Publish links to the publish-review page where mappings are
  validated before the version is cut, and is the ONE edit-mode action that
  stays a full navigation. Both are `DraftStatus` slots with stable ids. A
  shape-changing write streams them to the actor (§11b), and the projection
  broadcasts them whenever a draft opens or closes (`broadcast_draft_status`, on
  `DraftVersionStarted` and `FrameworkVersionPublished`): the pill over `framework_activity`, the button over
  `framework_publishers`, which the page subscribes to only for a viewer with
  publish rights (Lesson 40). Both broadcasts wait for the write to commit. (Draft lifecycle: see ADR-16/17.)
  - **Publishing runs in the background.** `Operations::Frameworks::PublishVersion`
    now *requests* a publish: it checks the ADR-17 gate, records a
    `FrameworkPublication` and enqueues `Frameworks::PublishVersionJob` (the
    per-person migration of ratings/evidence/comments does not fit a web
    request). The review page's confirm and an MCP agent's in-app approval
    both dispatch that one operation, so they share the lock. While a row is
    unfinished the Publish slot renders a **disabled "Publishing vN…" button**
    (`DraftStatus publishing: true`, read from
    `FrameworkPublication.in_flight_for?` by the controller — never by the
    view) and the review page's confirm is disabled too; a second request is
    refused by the partial unique index (`finished_at IS NULL`), not just the
    UI, and a row abandoned by a dead worker is reaped after
    `FrameworkPublication::STALE_AFTER`. The requester gets a
    `framework_published` notification with the outcome. The
    `FrameworkVersionPublished` event's projection re-broadcasts both
    `DraftStatus` slots (`broadcast_draft_status`) on the same streams that
    open them, so an open explorer drops the pill and button whoever
    published. The review page shows the last attempt's failure
    message for this draft. Edits made to the draft between the request and
    the job running are published with it — the job re-checks the gate, so a
    newly retired capability without a mapping fails the publish and says so.
  - **The review page says what the version changes**
    ([#497](https://github.com/mr-yum/growth-os/issues/497)). "What changes
    in vN" lists every shape-changing difference between the draft and the
    published framework — capabilities and categories added or archived,
    roles a capability gains or loses, levels added or moved, expectations
    added — with how many open-cycle people hold a role a removal or archive
    touches (snapshot role, else assignment, as every assessment reader
    resolves it).
    `Frameworks::DraftChangesQuery` diffs the edit-mode graph against the
    published read model rather than walking events, comparing bindings by
    (capability, role): a binding removed and re-added mints a new id but
    changes nothing for an assessment. An archive is listed once, not once
    per role it drops, and its archived list is `RetiringCapabilitiesQuery`'s,
    so it can't disagree with the mapping form below it. The page reads it through
    `Operations::Frameworks::DraftChanges` (MCP `frameworks_draft_changes`),
    so an agent can read what it is about to publish. Before this, the page
    listed only archives, and a draft that took three capabilities off a role
    read "nothing to migrate".
  - **Publish-review mappings are ONE form.** Every retiring capability's row
    (type + survivor) posts together to `MigrationMappingsController#create`
    as `migration_mappings[<i>][…]` → `Operations::Frameworks::DefineMigrationMappings`,
    one atomic write (`CommandHandler#batch`): unchanged rows emit no event,
    an undecided row (blank type) is left alone, rows still missing a survivor
    are left unsaved and named in the flash. The per-row "Save mapping" it
    replaced reloaded the page and dropped the other rows' unsaved selections
    (#399). Each row is its own `mapping-form` Stimulus scope (a `div`, not a
    `form`) so the survivor toggle stays per row.
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
  stays a ghost meanwhile. The submit answers the toast + draft-status stream
  and `add-level-form` then dispatches `org-structure:updated` →
  `matrix#refresh`: a level adds a **column to every row**, a grid change no
  surgical stream can express (§11b). Duplicate ordinals are blocked
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
  (`RoleFamilyNameFrame` / `RoleNameFrame`, rendered by `RoleTree`) and on each
  per-role **level title** in the matrix header (`LevelTitleFrame`, rendered by
  `MatrixHeader#full_title_badges`). All three pencils need edit mode **and**
  `can_edit_structure`, like every other tree affordance: reaching edit mode
  only takes suggest rights, so a suggest-only viewer sees the names (a draft
  level's title still wiggles) but no pencil whose save the policy would refuse
  (#401). These use
  the shared `InlineEditable` pencil/form helpers but — unlike capability /
  category text — are **direct edits, NOT the suggested-edit path**: org
  structure has no approval tier, so there is no pending decoration, no
  editing/suggesting toggle interaction, and no `SuggestionDecoration`. Each
  PATCHes a thin controller (`Frameworks::{RoleFamilies,Roles,Levels}Controller`)
  that dispatches `Operations::Frameworks::{UpdateRoleFamily,UpdateRole,UpdateLevel}`
  (shape-preserving → applies live, no draft) and re-renders the frame. Gated by
  `FrameworkPolicy#{update_role_family?,update_role?,update_level?}` (the
  `edit_structure?` bar). A refused rename answers **422 with the frame** — the
  message inline plus the typed text, so the editor re-opens with it (Lesson
  26). A department rename saved unchanged is a no-op, not a refusal. **Constraints:** the level-title pencil shows only when
  the header renders **full titles** (≤ 3 roles selected); the compact-code view
  (> 3 roles) stays read-only — titles are hidden there, so the user renames with
  fewer roles in scope. `MatrixDataBuilder#build_merged_levels` carries a
  per-role `level_id` in each `role_codes` entry so the editor targets one
  specific level. The inline pencils are **rename-only** — code / track / the
  entry flag are edited via the role-row kebab's dialogs (see §11).
- **Framework rename** — the header's `<h1>` is a `FrameworkNameFrame` with the
  same hover-pencil inline editor (#405). The same *shape* as the org-structure
  renames — a direct, shape-preserving edit that PATCHes a thin controller
  (`Frameworks::NamesController`, `PATCH /frameworks/:id/name`) dispatching
  `Operations::Frameworks::Rename` (web + MCP `frameworks_rename`), applied
  live with no draft — but a **narrower bar**: `FrameworkPolicy#rename?` is
  tenant admin **or framework owner**, because the name is the framework's
  identity across the index, cycles, assessments and MCP payloads, not content
  an editor curates. The controller threads `can_rename` and the pencil renders
  only in edit mode with it; everyone else (and view mode) gets the plain
  heading. The editor host is a `<div>` around the `<h1>`, not the heading —
  the shared editor appends its `<form>` to the host and a form isn't phrasing
  content. Like the org-structure renames, a rejected save answers **422
  with the frame** (message + attempted value, Lesson 26). The aggregate
  no-ops on an unchanged name (no event, no feed entry) and strips whitespace.
  The `<title>` catches up on the next full navigation. Feed:
  `framework_renamed` ("Renamed the framework to “…”", edits group,
  framework-level anchor).
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

**Shared modals under one `modal` controller.** Every dialog in edit mode is an
embedded `Kit::Modal` on the explorer **root**, and one `modal` Stimulus
controller drives all of them. Root-mounted for every edit-mode viewer:
reject-suggestion (§12), resolve-clarification and request-clarification (§12a),
and archive-illustration (§11b). Root-mounted for `can_edit_structure` holders:
archive(-capability), add-capability, add-category, archive-category,
binding-editor, level-editor, add-level, and the role-family and role dialogs
(each rendered twice, in `:new` and `:edit` shape) — eleven overlays in
`ShowView#structural_modals`. Each trigger names its overlay via
`data-modal-target-id="<overlay id>"`; the controller opens that overlay
(falling back to the lone overlay when a page has only one — so the assessment
evidence / delegation modals are unchanged). Feature controllers prefill from
the `modal:open` event's `dataset`: `add_capability_form` (category id/name),
`archive_form` (capability id/name, needs-mapping, hides self from survivors),
`mapping_form` (toggles the survivor select by mapping type),
`archive_category_form` (category id/name — no mapping),
`archive_illustration_form` (illustration id + excerpt), and the clarification /
reject / role / level form controllers listed in the Stimulus table.

These modals hold unsaved input (names, descriptions, migration mappings,
reject reasons), so outside-click dismissal is **off** — the explorer root's
`modal` controller leaves `dismissOnOutsideClick` at its default (false), so a
stray background click can't discard a half-filled structural form. They close
via the × button, Cancel, Esc, or a successful submit.

**Operations-first (web + MCP parity).** Add/archive/publish/mapping all dispatch
`Operations::Frameworks::*` (`AddCapability`, `AddCategory`, `ArchiveCapability`,
`ArchiveCategory`, `DefineMigrationMapping` (as-you-go, from the archive modal), `DefineMigrationMappings` (the publish-review form's batch), `PublishVersion`) so the web
controllers and the MCP tools share one implementation (the house rule).
`AddCategory` is shape-preserving (applies live).
`AddCapability`/`ArchiveCapability`/`ArchiveCategory` are shape-changing → they
**auto-open a draft** and the affected entity is **deferred from the published
read model until publish** (see Hard-Won Lesson 17). `ArchiveCategory` has no
migration mapping (categories carry no ratings) but the aggregate rejects it
while active capabilities remain — empty the category first.

### 11a. One hover cluster, one kebab machinery, one add treatment (#380)

Three vocabularies the grid used to have several of. All three are also the
edit matrix's biggest remaining payload lever after #378/#379 — the grid
repeats each of them thousands of times.

**One hover cluster.** An entity's controls appear in the fixed order
**pencil · discuss · kebab**, and reveal *together* on hover or focus-within of
the entity's own **row / cell / item** — never on the text span. The entity
carries `data-hover-cluster="<scope>"` and every control in its cluster carries
`data-cluster="<scope> <kind>"`, kind ∈ `inline | kebab | standalone`; one CSS rule set in
`app/assets/tailwind/application.css` pairs them. Scopes: `row` · `cell` ·
`ill` · `cat` (the grid) + `tree` · `hdr` (the role pane, the level titles).
The owner is the **row / cell / item**, never the text: the role tree's rename
pencil hangs off the tree row that already reveals the family's edit dialog and
the role's ⋮, so a tree row's controls appear at one moment too. The attribute
is emitted in edit mode only — view mode has nothing to reveal.
`Concerns::HoverCluster#render_hover_cluster` renders the cluster; a pencil that
belongs to the entity's own Turbo Frame (a capability name, a category name, an
expectation text — the frame re-render has to carry it, and the shared editor
resolves its host by `closest("[data-editor-action]")`) is rendered by that
frame via `render_inline_editor_pencil(scope:)` immediately before the cluster.

**`opacity: 0` still takes layout width — so where the text is tight, the
cluster must come out of the flow.** The grid can afford in-flow controls; the
role tree could not. In an 18 rem pane a role row's name box is ~190 px, and the
solo pill (~44 px) + rename pencil (~20 px) + ⋮ (~28 px) took half of it while
being invisible, so nearly every real name — "Analytics Engineer", "Commercial
Finance", "Product Management" — wrapped onto two lines and the tree became a
wall of them (reported from the field). The tree's rows therefore put the name
in a `relative flex-1 min-w-0` box and its controls in an absolutely-positioned
`.tree-actions` cluster over that box's right edge. Consequences:

- The name gets the row's whole width and is **never truncated** — `break-words`
  stays the fallback for a name longer than any pane would hold, and the pane is
  sized (below) so it is rarely reached.
- The cluster paints an **opaque mask** matching the row's hover background, but
  only under the conditions that reveal it (`:hover` / `:focus-within`, and the
  pane background on `pointer-coarse`). Painted unconditionally it would blank
  the tail of a name whose controls are invisible.
- A tree pencil is now **outside** its name frame, so it names the frame with
  `data-editor-host-frame` — the same escape hatch a kebab's "Edit…" uses. It
  also survives that frame's PATCH re-render for free.
- **The cluster hides while the row's editor is open**
  (`:has([data-editor-form])`). The editor takes the row's whole width, so the
  cluster would sit over its textarea and clip a save error; none of its
  controls apply mid-edit, and Cancel or a save brings them back.

Two more things fall out of the cluster rule itself:

- **No interpolated Tailwind token, so Hard-Won Lesson 12 can't bite here** —
  there is no class name to build, only a scope name.
- **`pointer-coarse` collapses the cluster to the kebab.** `inline` controls are
  `display: none` there and the kebab stays visible, which is why every kebab
  also carries the cluster's **Edit…** and **Discuss…** as menu items. A
  kebab-borne "Edit…" is not inside its editor host, so it names the host's
  frame with `data-editor-host-frame` and `field-editor#open` resolves it
  (documented in that controller's header). A control whose cluster has **no
  kebab** — a level title, the org-structure renames, a pending ghost's amend
  pencil — is marked **`standalone`** and stays visible instead: hiding it there
  would make it unreachable on touch rather than relocating it. The invariant
  (every `inline` control shares its cluster with a `kebab`) is pinned by
  `explorer_menu_system_test.rb`, because `resize_to` cannot flip
  `pointer: coarse` and no viewport test would catch a violation.
- **A menu item that opens a modal names its focus-return target.** The item is
  destroyed with the menu, so the dialog has no surviving invoker to hand focus
  back to on close — every re-resolution path in `modal_controller` assumes a
  `Kit::Dropdown`. Built items therefore carry `data-modal-focus-return="<the
  trigger's id>"`, and closing the menu with focus still inside it returns focus
  to the trigger (the APG menu-button contract, and what makes Tab-out land on
  the control after the kebab).

**One kebab machinery.** The grid ships a **bare trigger button** carrying only
the ids and permission flags its menu needs;
[`explorer_menu_controller.js`](../../../app/javascript/controllers/explorer_menu_controller.js) —
mounted ONCE on the explorer root, event-delegated — builds the menu on open
from the trigger's dataset plus the coordinates the grid already publishes
(`tr[data-capability-id]`, `tr[data-capability-name]`, `tr[data-category-id]`,
`[data-reorder-item-id]`). Route templates ride once on the root
(`data-explorer-menu-paths-value`), so no Rails path is hand-written in JS.
Rules:

- **Authority stays server-side.** A viewer who cannot approve never receives
  the suggestion id, so the builder has no Approve/Reject to compose.
- **Built items keep the `data-*` the real behaviour needs**, so they still
  drive the same controllers as before — `modal#open`, `field-editor#open`,
  `reorder-move#move`, `reorder-list#moveUp`, `suggestion-action#approve`.
  Those now mount on the ONE open menu instead of on hundreds of closed ones.
- **Every Move item that exists can move, and every menu reads its own
  position from the DOM.** All three (capability, category, illustration) find
  their neighbours at open time — capability rows by `[data-movable]` within
  their category's `<tbody>`, categories by sibling `<tbody data-category-group>`,
  illustrations by the `reorder-list` items — because every reorder now moves
  the node in place (§11b) and a server-sent neighbour id is stale the moment
  the first move lands. The capability and category menus once carried
  server-sent prev/next ids and could afford to, only because the whole matrix
  re-rendered after each move.
- **The menu is inserted next to its trigger** (`position: fixed`, viewport
  clamped, flips above when there is no room below) — not at the root — so a
  menu item can still reach its entity by `closest(…)`. It **follows its
  trigger on scroll** rather than dismissing, and closes on Esc (focus returns
  to the trigger), an outside click, `modal:open`, or acting on any item except
  Approve (which swaps itself to "✓ Approved" in place).
- **The trigger's stacking context is lifted while the menu is open.** `fixed`
  escapes overflow clipping but not paint order (Hard-Won Lesson 31), so the
  controller raises the nearest positioned+z-indexed ancestor to `z-index: 9`
  for the life of the menu and restores the inline value on close.
- **ARIA is unchanged**: `aria-haspopup` / `aria-expanded` on the trigger,
  `role="menu"` + `role="menuitem"` on the built menu, ArrowUp/Down/Home/End
  roving focus, and focus-within reveal so a keyboard user can reach the
  trigger at all.
- The **role tree's** per-role ⋮ deliberately stays on `Kit::Dropdown`
  (`strategy: :fixed`): it is one menu per role in a scrolling pane, not
  thousands in a grid, and it isn't in the matrix frame at all. Its shared
  chrome lives in `Concerns::KebabChrome`.

**One reorder treatment, one add treatment.** Reorder is **"Move up" / "Move
down" kebab items everywhere** (the category and illustration ↑/↓ chevrons are
gone). Add is one dashed ghost (`HoverCluster#render_add_affordance`,
`.explorer-add`), **always visible** in edit mode so it is keyboard reachable
and discoverable on touch — used by "+ Add category" (stats bar), "+ Add
capability" (category footer), "+ Add expectation" (empty cell, previously
hover-only) and "+ Add example" (expanded row). Its label is
**left-anchored, and an add row sits in the column it adds to** — the
add-capability row is a single sticky cell in the capability column, NOT a
`colspan`-ed row: a centred label in a matrix-wide row lands off-screen at the
default horizontal scroll, leaving an empty dashed box where the affordance
should be (found by #380's visual pass).

**Icons are a sprite.** `Components::Kit::IconSprite` renders one `<symbol>` set
per page from `Shell::PageLayout`; call sites use
`icon("pencil", class: "w-3 h-3")` → `<svg><use href="#icon-pencil"></svg>`. The
grid drew the same handful of glyphs 758 times in the matrix and 208 times in
every expanded row.

Measured on the seeded me&u framework (edit matrix, `track=both`), against the
post-#379 baseline: **1,222,619 → 946,778 B (−22.6%)**, `data-controller`
mounts **111 → 0**, `Kit::Dropdown` mounts **38 → 0**, `<svg>` bytes
**218,515 → ~103,000** (count rises to 1,040 because every cell now has a
kebab, but each is a ~55-byte `<use>`). One expanded row (the widest
capability): **362,526 → 228,000 B (−37%)**, controller mounts **70 → 0**.

### 11b. One write-response contract (#381)

"I changed something" used to have **seven** different outcomes in edit mode:
a silent frame swap, a Turbo Stream append, a **full page reload** with a Rails
flash (add capability / expectation / category / level, archive capability /
category — 7.8 MB, scroll position and every loaded expanded row gone), a
**native `confirm()` then a full reload** (archive illustration), a DOM move,
or a **whole-matrix re-fetch** (reorder capability / category — ~950 KB and
seconds of client time to move two rows). Feedback ranged from a green flash on
a page you had just lost your place in, to nothing at all.

**Every edit-mode write to the grid now answers a Turbo Stream touching exactly
the rows it changed, plus one toast.** Writes made inside a modal editor that
stays open (binding editor, levels editor) and the role-tree writes re-render
their own Turbo Frame instead, and a reorder answers only the toast while
`reorder-move` moves the node client-side (below). The rules:

1. **Never redirect.** `Frameworks::{Expectations,Capabilities,Categories,
   Levels}Controller#create`, `Capability/Category/IllustrationArchivesController`
   and both reorder controllers answer streams. **Publish is the only edit-mode
   action that stays a full navigation** — the review page is a deliberate
   confirmation step.
2. **`matrix#refresh` survives for two kinds of change only**: the documented
   non-surgical suggestion-resolution fallback (§12 invariant 4), and the
   **org-structure edits that change the matrix HEADER** — adding a level (a
   column on every row), and the role / level-code edits the role kebab's
   dialogs make. Everything else is a last resort (Lesson 23).
3. **A refused write stays in the region too** — 422 + the same toast, never a
   redirect. Turbo's `StreamObserver` claims a turbo-stream response on
   `turbo:before-fetch-response` whatever the status, so a 422 stream is
   processed in place exactly like a 200 one. Losing your scroll position is
   not an acceptable price for a typo.
4. **The copy distinguishes applied from proposed** ("Added an expectation." vs
   "Proposed a new expectation for review.", "Archived …" vs "Proposed
   archiving … for review."). The editing/suggesting toggle plus the viewer's
   authority decide which happened, and nothing else on screen says so.
5. **Confirmation is a modal, never `confirm()`.** The illustration archive was
   the last native dialog; it now opens the root-mounted
   `ArchiveIllustrationModal` like every other destructive action — themed,
   focus-managed, and with somewhere to type a reason.

**The addressable units.** Streams need anchors, and the grain of the anchor is
the grain of the update:

| Unit | Anchor | Written by |
|---|---|---|
| Capability | `capability-row-<id>` — the compact `<tr>` | add (insert) · archive (replace) |
| Category | `category-group-<id>` — its own `<tbody>` | add (append) · archive (remove) · reorder (move) |
| Cell | `cell-<capability_id>-<ordinal>` — the `<td>` | author an expectation |
| Draft status | `framework-draft-badge` / `framework-publish-action` | every shape-changing write |
| Toast | `framework-write-status` | every write |

Three consequences worth stating outright:

- **One `<tbody>` per category** (`MatrixCategoryGroup` renders its own) is what
  makes a category a single addressable, movable node. Category collapse is
  unaffected: `matrix#toggleCategory` walks siblings from the header row, which
  now stop at the tbody boundary instead of at the next header.
- **An archive replaces only the compact row**, never the expanded one — that
  would discard content the user may have loaded, and the strikethrough on a
  hidden row is cosmetic (it re-fetches fresh on its next expand).
- **A streamed row must be built against the same scope as the grid around it.**
  The role/track selection and the text filter ride on every write form via
  `tree-scope-fields` (the `formdata` event, so a selection changed after the
  modal opened still counts), and the controllers rebuild through the shared
  `Frameworks::ExplorerMatrix` concern — the same `MatrixDataBuilder` call the
  page itself made. A capability the current filter hides simply gets no row
  fragment: the toast still lands and the grid catches up on the next render.

**The toast** is a persistent `role="status"` live region in the shell
(`Views::Frameworks::Explorer::WriteStatus`), which every write **updates**
rather than replaces — a live region re-created per message is not reliably
announced. Messages use the app's existing flash vocabulary and auto-dismiss via
the shared `flash` controller.

**Reorder moves nodes, it does not refresh.** `reorder-move` repositions the
capability's compact + expanded rows (which must stay adjacent — the accordion
pairs them by capability id) or the category's `<tbody>`, and the kebab's Move
items **read their neighbours from the DOM at open time**. A server-sent
neighbour id is stale the moment the first in-place move lands — the rule the
illustration menu already followed (§11a), now shared by all three.
