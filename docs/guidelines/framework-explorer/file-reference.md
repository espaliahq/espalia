# Framework Explorer — File Reference

> Part of the [framework-explorer.md](../framework-explorer.md) guide set. Read this when: looking for the file that owns a piece of the explorer.

## File Reference

| File | Purpose |
|------|---------|
| `app/views/frameworks/show_view.rb` | Three-pane shell, stats bar, layout; hosts the write-status region + the DraftStatus slots (§11b) |
| `app/controllers/concerns/frameworks/write_response.rb` | The ONE write-response contract — toast, draft-status and row/category/cell stream builders shared by every edit-mode write (§11b) |
| `app/controllers/concerns/frameworks/explorer_matrix.rb` | The matrix build + per-viewer flags, shared by the read actions AND every write that streams rows back; also the conditional-GET key and the expanded row's single-capability path (#383) |
| `app/models/frameworks/entity_labels.rb` | The ONE entity-type → user-facing word map (`role_illustration` → "Example") — suggestion badges plus every aggregate / Operation error message that reaches a flash |
| `app/models/frameworks/collaborator_roles.rb` | One viewer's collaborator roles on one framework, loaded once and answered in memory |
| `config/initializers/release_id.rb` | The running build's identifier, mixed into the conditional-GET keys so a deploy can't be answered with the previous release's HTML |
| `test/performance/explorer_payload_test.rb` | Byte + structural ceilings on the matrix frame and one expanded row — runs in the default suite |
| `app/views/frameworks/explorer/write_status.rb` | The persistent `role="status"` toast region (updated, never replaced, so it stays announceable) |
| `app/views/frameworks/explorer/write_status_message.rb` | One transient toast — applied (`:ok`) vs refused (`:error`), auto-dismissed by the shared `flash` controller |
| `app/views/frameworks/explorer/draft_status.rb` | The `vN draft` pill and the Publish button as two addressable slots — broadcast by the projection when a draft opens or closes, and streamed to the actor by every shape-changing write |
| `app/views/frameworks/explorer/pending_count_badge.rb` | The header's "N pending" badge — replaced from the `framework_activity` broadcast so it can't lag the pane |
| `app/views/frameworks/explorer/archive_illustration_modal.rb` | Shared archive-example modal (confirm + optional reason) — replaced the menu's native `confirm()` |
| `app/javascript/controllers/archive_illustration_form_controller.js` | Prefills that modal from the illustration kebab's trigger dataset |
| `app/views/frameworks/matrix_frame_view.rb` | Turbo Frame wrapper for matrix endpoint |
| `app/views/frameworks/explorer/role_tree.rb` | Department → Family → Role tree; in view mode, a viewer with an assignment in the framework gets a "My ratings →" `standalone` cluster link per role, landing on their assessment read against it ([assessments/role-lens.md](../assessments/role-lens.md) → *Role lens*); family list wrapped in the `role-tree-families` Turbo Frame. The per-family edit-dialog trigger, the role-row ⋮ kebab, the department-header editor and the "+ Add role" / "+ Add role family" rows and the `RoleFamilyNameFrame` / `RoleNameFrame` rename pencils all need `mode == :edit` **and** `can_edit_structure` (`#structure_editable?`) — the `edit_structure?` bar their writes enforce (#401). Hides ghost roles/families in view mode, wiggles them (+ "No roles yet") in edit mode |
| `app/views/frameworks/explorer/framework_name_frame.rb` | The header `<h1>` + edit-mode inline rename editor for an admin / owner (`can_rename`; direct edit, no suggestion path; 422-with-frame on a rejected save) |
| `app/views/frameworks/explorer/role_family_name_frame.rb` | Role-family name + edit-mode inline rename editor (direct edit, no suggestion path) |
| `app/views/frameworks/explorer/role_family_edit_modal.rb` | Shared role-family dialog — `:edit` (per-family trigger, PATCH) or `:new` (tree-foot "+ Add role family", POST → `AddRoleFamily`); submit re-renders the `role-tree-families` frame so the family re-groups / appears ghost-wiggled |
| `app/views/frameworks/explorer/add_role_modal.rb` | Shared role modal — `:new` ("+ Add role" trigger, family implied, POST → `AddRole`) or `:edit` (role-row kebab, PATCH via id template → `UpdateRole`) |
| `app/views/frameworks/explorer/level_editor_modal.rb` | Shared "Edit levels" modal (embedded) — body is the `level-editor` Turbo Frame; opened by the role-row kebab. Carries the shared `frame-error` controller + `Kit::FrameLoadError` block (audit issue #365): an un-handled `turbo:frame-missing` otherwise renders Turbo's own "Content missing" into the editor, with no retry |
| `app/views/frameworks/explorer/level_editor_frame.rb` | Levels-editor frame body — per-row title/code saves, radio-with-clear entry flag, add row with in-frame errors; re-renders in place |
| `app/javascript/controllers/level_editor_form_controller.js` | Points the level-editor frame at the clicked role on `modal:open`; fires `org-structure:updated` after in-frame saves |
| `app/views/frameworks/explorer/concerns/ghost_entities.rb` | Ghost predicates (`published_role?` / `ghost_role?` / `ghost_role_family?`) + the `role_ghost_title` / `role_family_ghost_title` tooltips ("Not in the published framework yet — appears once it has published levels"), derived from published-level presence |
| `app/javascript/controllers/add_role_form_controller.js` | Prefills the role modal from its trigger (`:new` — family id + clears; `:edit` — action template + name/code/track); fires `org-structure:updated` after an edit; selection rides along via `tree-scope-fields` |
| `app/operations/operations/frameworks/{add_role_family,add_role}.rb` | Shared web + MCP operations — org-structure adds (shape-preserving, live; new entity is a ghost until publish) |
| `app/operations/operations/frameworks/add_level.rb` | Shared web + MCP operation — add a level (shape-changing: auto-opens a draft, deferred until publish; guards duplicate ordinals against the graph) |
| `app/views/frameworks/explorer/add_level_modal.rb` | Shared "new level" modal (ordinal + title + code + entry flag; role implied by the role-row kebab's "Add level…" trigger) → `Frameworks::LevelsController#create` |
| `app/javascript/controllers/add_level_form_controller.js` | Prefills the add-level modal from the role kebab's "Add level…" trigger (role id/name + next free ordinal); selection rides along via `tree-scope-fields` |
| `app/views/frameworks/explorer/department_name_frame.rb` | Department group header; inline-renameable in edit mode → bulk relabel of every family in the group |
| `app/javascript/controllers/role_family_edit_form_controller.js` | Prefills the role-family dialog from the trigger dataset (`:edit` fills, `:new` clears); copies the current `roles[]`/`track` selection from the URL so the re-rendered tree stays checked |
| `app/javascript/controllers/tree_scope_fields_controller.js` | Injects the current matrix scope — `roles[]`, `track` and the text filter `q` — into a form at submit (`formdata` event): the department-rename editor, plus every structural modal and add-affordance whose surgical stream must re-render rows against the grid's scope (§11b) |
| `app/operations/operations/frameworks/rename_department.rb` | Shared web + MCP operation — bulk-rename a department across its role families (fans out to `UpdateRoleFamily`; blank target ungroups) |
| `app/controllers/frameworks/departments_controller.rb` | `PATCH /frameworks/:id/departments` — dispatch `RenameDepartment`, re-render the `role-tree-families` frame |
| `app/controllers/concerns/frameworks/role_tree_families_frame.rb` | Shared `role-tree-families` frame render (selection-preserving), used by the role-family + department controllers |
| `app/views/frameworks/explorer/role_name_frame.rb` | Role name + edit-mode inline rename editor (direct edit) |
| `app/views/frameworks/explorer/level_title_frame.rb` | Per-role level title + edit-mode inline rename editor (full-title header mode only) |
| `app/views/frameworks/explorer/matrix.rb` | Table container + empty state |
| `app/views/frameworks/explorer/matrix_header.rb` | Sticky column headers with responsive titles; renders `LevelTitleFrame` per role in full-title (≤3 roles) edit mode, with the rename pencil only for `can_edit_structure` |
| `app/views/frameworks/explorer/matrix_category_group.rb` | Collapsible category with capability rows; sticky header renders CategoryNameFrame + CategoryDescriptionFrame |
| `app/views/frameworks/explorer/expanded_row.rb` | The expanded (illustrations) row — shipped as a hidden placeholder, served loaded by `FrameworksController#expanded_row` / `#edit_expanded_row` on first expand (Hard-Won Lesson 25) |
| `app/views/frameworks/explorer/matrix_row.rb` | Compact capability row + the `ExpandedRow` placeholder; row-actions kebab trigger (unconditional in edit mode) — its menu carries inline Approve/Reject of pending name/description edits + Edit name/description… + Discuss… + Move up/down + Edit roles… + Archive (§11, §11a, §12, §12a) |
| `app/views/frameworks/explorer/matrix_cell.rb` | Expectation text + hover "Discuss…" button (§12a) + example-count indicator + pending-count pill (≥2); renders "+ Add expectation" for an empty-but-applicable cell (any edit-mode viewer) |
| `app/views/frameworks/explorer/illustration_frame.rb` | Real illustration row in expanded cell — pending-edit decoration, then the hover cluster: pencil, then the ⋮ kebab (Approve/Reject when approvable + Edit example… + Discuss… + Move up/down + Archive…) |
| `app/views/frameworks/explorer/pending_illustration_frame.rb` | Ghost entry for pending-create illustration suggestions (edit mode only) — pencil (amend/alternative) + Approve/Reject kebab for tier-authority viewers |
| `app/views/frameworks/explorer/new_illustration_frame.rb` | "+ Add example" affordance (edit mode only) |
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
| `app/views/frameworks/explorer/binding_editor_modal.rb` | Shared "Edit roles" modal (embedded) — body is the `binding-editor` Turbo Frame; opened by the row kebab. Same `frame-error` + `Kit::FrameLoadError` wiring as the level-editor modal (audit issue #365) — the frame-failure machinery is documented in [assessments.md](../assessments.md)'s Stimulus controllers table, where it was extracted from the evidence modal |
| `app/views/frameworks/explorer/binding_editor_frame.rb` | Binding-editor frame body — lists role bindings (weight + Remove) + add-role form; re-renders in place on each action |
| `app/views/frameworks/publication_review_view.rb` | Publish-review page — what the version changes, one form for every retiring capability's mapping, the latest publish request's state, and the confirm that requests the background publish |
| `app/views/frameworks/explorer/expectation_text_frame.rb` | Expectation text + edit-mode inline editor |
| `app/views/frameworks/explorer/concerns/suggestion_decoration.rb` | Shared decoration class helper (wavy underline / strikethrough) + the squiggle's open-card click affordance (§10) |
| `app/views/frameworks/explorer/concerns/menu_items.rb` | The grid's kebab triggers — `render_menu_trigger` + `approval_menu_data`; the menu itself is built client-side (§11a, #380) |
| `app/views/frameworks/explorer/concerns/hover_cluster.rb` | The ONE hover-cluster rule (scopes + `render_hover_cluster`) and the ONE add affordance (`render_add_affordance`) (§11a) |
| `.tree-actions` (in `app/assets/tailwind/application.css`) | The role tree's floating row-action cluster — out of flow so it reserves no name width, masked only while revealed (§11a) |
| `app/views/frameworks/explorer/concerns/kebab_chrome.rb` | Shared ⋮ chrome for the remaining `Kit::Dropdown` kebab (the role tree) |
| `app/views/frameworks/explorer/concerns/sticky_column.rb` | Shared sticky capability-column styling + the NON-NEGOTIABLE opacity invariant and its current composites (Hard-Won Lesson 24, issue #371) |
| `app/views/frameworks/explorer/concerns/pending_archive.rb` | The ONE definition of "staged for archive in the open draft" (`pending_archive?`) + `STRIKETHROUGH_CLASSES`, shared by `MatrixRow` / `MatrixCategoryGroup` / `ExpandedRow` (§11) |
| `app/javascript/controllers/explorer_menu_controller.js` | ONE delegated kebab-menu controller for the whole grid (§11a) |
| `app/components/kit/icon_sprite.rb` | The ONE `<symbol>` set, rendered per page by `Kit::PageLayout`; call sites use `icon(name, class:)` |
| `app/components/helpers/icon_helpers.rb` | `icon("pencil", class: …)` → `<svg><use href="#icon-pencil">` |
| `app/controllers/concerns/frameworks/suggestion_authority.rb` | Resolves the viewer's `SuggestionApprovalAuthority` for controllers whose frame responses carry approval kebabs |
| `app/controllers/concerns/frameworks/illustration_frame_context.rb` | Re-threads the discussion context (comment glyph + "Discuss…" context line) any controller swapping a single `IllustrationFrame` must supply, or the swap silently drops it (Lesson 13/16 class) |
| `app/controllers/concerns/frameworks/suggestion_resolution_streams.rb` | Surgical inline approve/reject responses — Turbo Streams replacing just the affected entity's frame; nil → 204 → client full-refresh fallback (Hard-Won Lesson 23) |
| `app/views/frameworks/explorer/concerns/search_highlight.rb` | Phlex `<mark>` highlighting of search-match terms (§4a) — safe, token-AND, overlap-merged |
| `app/views/frameworks/explorer/concerns/inline_editable.rb` | Shared Phlex helpers for the edit pencil, the `data-editor-*` host contract (`field_editor_data`) and the inline save-error line; `inline_editor_value` seeds the editor with the pending proposal |
| `app/views/frameworks/explorer/field_editor_template.rb` | The ONE inline-edit `<form>`, inert in a `<template>` on the explorer root — cloned into place by `field-editor` (#379) |
| `app/javascript/controllers/field_editor_controller.js` | The shared inline editor — pencil delegation, keyboard, autogrow, Save/Propose, error re-open, dirty guard |
| `app/views/frameworks/suggestions/inline_indicator.rb` | Amber "N pending" count pill (used in matrix cells) |
| `app/models/frameworks/matrix_data_builder.rb` | Data transformation (merge levels, filter capabilities, keep empty categories in edit mode, per-field `latest_by_field` pending-edit descriptors) |
| `app/models/frameworks/suggestion_diff.rb` | Grapheme-level inline diff between original and proposed text; fallback on density threshold |
| `app/views/frameworks/suggestions/panel_frame.rb` | (Legacy) suggestion-only panel content — reached ONLY by `SuggestionsController#render_panel` (`GET …/suggestions?layout=panel`), never the context pane (§9) |
| `app/views/frameworks/activity/panel_frame.rb` | Context pane Turbo Frame content — activity feed (focus header + breadcrumb-with-× / gesture hint + count + "Show all" clear link + filter chips + entry list + load-older footer + empty state) |
| `app/views/frameworks/activity/load_more.rb` | "Load older activity" footer (`#framework-activity-load-more`) — indication + affordance for the next batch |
| `app/views/frameworks/activity/count.rb` | Loaded-entry count (`#framework-activity-count`) — replaced by the load-older Turbo Stream |
| `app/views/frameworks/activity/show.turbo_stream.erb` | Load-older response — append older entries + replace the footer + the count |
| `app/javascript/controllers/activity_more_controller.js` | "Load older" — GET next batch as a Turbo Stream via `@rails/request.js` |
| `app/views/frameworks/activity/entry.rb` | One activity entry — `KIND_DOT` / `KIND_GROUP`, summary + context line + actor·timestamp footer, matrix-navigation data attrs, **inline Approve / Reject action row when pending + viewer-authorised** (§12) |
| `app/views/frameworks/explorer/reject_suggestion_modal.rb` | Shared reject-suggestion modal (optional reason) — explorer root, edit mode (§12) |
| `app/models/frameworks/suggestion_approval_authority.rb` | Per-viewer approval authority value object — computed once, gates the actionable feed (§12) |
| `app/operations/operations/frameworks/{approve,reject,amend,withdraw}_suggestion.rb` | Shared web + MCP suggestion-lifecycle operations (§12) |
| `app/operations/operations/frameworks/{request,resolve}_clarification.rb` | Shared web + MCP clarification operations — the non-proposal suggestion kind (§12a) |
| `app/views/frameworks/activity/suggestion_actions.rb` | The §12 Approve / Reject affordance pair — inline approve + the reject-modal dataset contract, shared by the feed entry and the pane card so they can't drift |
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
| `app/javascript/controllers/framework_explorer_controller.js` | Layout shell, both pane toggles (inline column / slide-over per breakpoint), the measured `--explorer-offset`, role count (§7) |
| `app/javascript/controllers/tree_controller.js` | Role selection, solo mode, track filter |
| `app/javascript/controllers/matrix_controller.js` | Turbo Frame updates, row/category expansion, cell + category focus dispatch (shared with assessment) |
| `app/javascript/controllers/context_pane_controller.js` | Right-pane frame src + focus URL sync + activity-sync-signal observer (live reload) |
| `app/javascript/controllers/framework_search_controller.js` | Stats-bar text filter — debounced input → `framework-search:changed` (§4a) |
| `app/queries/frameworks/activity_feed_query.rb` | Reads the framework RES stream → reverse-chronological anchored activity entries; focus narrowing + `descriptor`. Names entities from the read model **supplemented by the creating event in the window** (so draft-added capabilities/expectations — deferred from the read model — are still named in "Added a capability" / binding entries), and pins the **level** on expectation entries ("Capability · L`n`") |
| `app/queries/frameworks/focused_suggestions_query.rb` | In-memory scope filter behind `SuggestionsController#render_panel` — not the context pane, which uses `ActivityFeedQuery` (§9) |
| `app/controllers/frameworks_controller.rb` | show / matrix / edit / edit_matrix actions (mode-aware) + `expanded_row` / `edit_expanded_row` (one capability's lazily fetched expanded row) |
| `app/controllers/frameworks/activity_controller.rb` | `GET /frameworks/:id/activity` — renders the activity-feed panel (focus-narrowed); at suggestion focus renders the card instead (`#render_suggestion_card` + `#sibling_discussions` + `#discussion_permalink`, §8/§12a/§13); Turbo Stream branch serves the load-older batches |
| `app/contexts/frameworks/projections/published_state.rb` | `broadcast_framework_activity` nudges the per-framework activity stream (replay-guarded) |
| `app/contexts/frameworks/projections/broadcasts_framework_activity.rb` | The shared nudge — the pane's sync signal AND the header's pending badge, so the two agree within one broadcast; plus the draft pill and Publish button when a draft opens or closes |
| `app/operations/operations/frameworks/recent_activity.rb` | MCP read-parity tool over `ActivityFeedQuery` |
| `app/controllers/frameworks/suggestions_controller.rb` | Standalone suggestion list + detail; create/approve/reject/amend/withdraw all dispatch `Operations::Frameworks::*` (create → `SuggestCreate`/`SuggestDelete`, always pending). approve/reject are inline-aware — `inline=1` (feed/grid) → surgical Turbo Stream, else 204; non-inline → redirect (§12) |
| `app/controllers/frameworks/illustrations_controller.rb` | Inline edit/create on illustrations (PATCH → `SuggestEdit`, POST → `SuggestCreate` with the edit/suggest toggle) |
| `app/controllers/frameworks/capabilities_controller.rb` | Inline edit on capability name **or** description (PATCH → `SuggestEdit`); add a capability (POST → `AddCapability`). Resolves the capability from the graph (incl. draft-added — Lesson 17) |
| `app/controllers/frameworks/categories_controller.rb` | Inline edit on category name **or** description (PATCH → `SuggestEdit`); add a category (POST → `AddCategory`) |
| `app/controllers/frameworks/expectations_controller.rb` | Inline edit on expectation description (PATCH → `SuggestEdit` — resolves from the graph for draft-added, Lesson 17); author an expectation in an empty cell (POST → `SetBehaviouralExpectation`, suggest/approve path) |
| `app/controllers/frameworks/capability_archives_controller.rb` | Archive a capability from the row kebab (POST → `ArchiveCapability`) |
| `app/controllers/frameworks/capability_bindings_controller.rb` | Binding editor — index (frame) / create / update / destroy → `{Add,Update,Remove}CapabilityRoleBinding`, re-rendering the frame |
| `app/controllers/frameworks/category_archives_controller.rb` | Archive an empty category from the header kebab (POST → `ArchiveCategory`) |
| `app/controllers/frameworks/names_controller.rb` | `PATCH /frameworks/:framework_id/name` — rename the framework from the header pencil → `Operations::Frameworks::Rename`; re-renders the name frame (422 + frame + attempted value on a rejected save). Direct edit, admin / owner only |
| `app/controllers/frameworks/{role_families,roles,levels}_controller.rb` | Direct (PATCH) edits of role family / role / level from the tree + header → `Operations::Frameworks::{UpdateRoleFamily,UpdateRole,UpdateLevel}`; all three also serve POST creates from the add modals → `{AddRoleFamily,AddRole,AddLevel}` (`role_families`/`roles` re-render the `role-tree-families` frame; `levels` answers the write-response contract — the `level-editor` frame from the levels editor, else toast + draft-status streams, with `add-level-form` firing `org-structure:updated` because a level adds a column, §11b). `role_families` serves both the inline rename (re-renders the name frame) and the edit dialog (forwards changed fields only, re-renders the `role-tree-families` frame on the `Turbo-Frame` header). Direct edit, not the suggest path. |
| `app/controllers/frameworks/illustration_archives_controller.rb` | Archive an illustration from the expanded-row control (POST → `ArchiveIllustration`) |
| `app/controllers/frameworks/illustration_reorders_controller.rb` | Move an illustration before/after a sibling (POST → `ReorderIllustrations`; 204, client moves the DOM node) |
| `app/controllers/frameworks/category_reorders_controller.rb` | Move a category before/after a visible sibling (POST → `ReorderCategories`; toast stream → `reorder-move` moves the category's `<tbody>` in place — §11b) |
| `app/controllers/frameworks/capability_reorders_controller.rb` | Move a capability before/after a movable sibling in its category (POST → `ReorderCapabilities`; graph-resolved, toast stream → `reorder-move` moves the row pair in place — §11b) |
| `app/javascript/controllers/reorder_move_controller.js` | Single-move POST menu item — renders the response's toast stream, then moves the capability's row pair / the category's `<tbody>` in place (§11b); mounts on the open menu, not on the grid |
| `app/javascript/controllers/reorder_list_controller.js` | Move up/down within a list — POSTs the neighbour-relative move, repositions the item's node on success (the illustrations `<ul>` keeps the mount; the buttons are menu items) |
| `app/controllers/frameworks/publications_controller.rb` | Publish-review page (`new`, via `Frameworks::RetiringCapabilitiesQuery`) + request the publish (`create` → `PublishVersion`, which records a `FrameworkPublication` and enqueues the job) |
| `app/controllers/frameworks/migration_mappings_controller.rb` | Save every migration mapping on the publish-review page in one submit (POST → `DefineMigrationMappings`) |
| `app/operations/operations/frameworks/define_migration_mappings.rb` | Batch mapping save shared by the review page and MCP — triages unchanged / undecided / incomplete rows, writes the rest atomically |
| `app/queries/frameworks/draft_changes_query.rb` | What publishing the draft changes — a graph-vs-published diff, bindings compared by (capability, role), with open-cycle reach |
| `app/operations/operations/frameworks/draft_changes.rb` | Shared web + MCP read (`frameworks_draft_changes`) over that query — the review page's "What changes in vN" |
| `app/queries/frameworks/retiring_capabilities_query.rb` | Retiring capabilities + their mappings from the edit-mode graph — the review page's rows and the publish request's gate |
| `app/models/framework_publication.rb` | A publish request and its outcome; one unfinished row per framework holds the in-flight lock |
| `app/jobs/frameworks/publish_version_job.rb` | Runs the publish as the requester, records the outcome, notifies them (`FrameworkPublishedNotifier`) |
| `app/operations/operations/frameworks/{add_capability,add_category,archive_capability,archive_category,archive_illustration,define_migration_mapping,publish_version}.rb` | Shared web + MCP operations for structural edits / publish (§11). `archive_capability`/`archive_illustration` are toggle+authority-driven (direct vs suggestion). |
| `app/operations/operations/frameworks/{add,update,remove}_capability_role_binding.rb` | Shared web + MCP binding operations — add/remove (shape-changing, draft) and weight/tolerance update (shape-preserving). |
| `app/operations/operations/frameworks/reorder_illustrations.rb` | Shared web + MCP operation — reorder one expectation × role's illustrations (complete-list, permutation-validated, shape-preserving). |
| `app/operations/operations/frameworks/reorder_categories.rb` | Shared web + MCP operation — reorder the active capability categories (complete-list, permutation-validated, shape-preserving). |
| `app/operations/operations/frameworks/reorder_capabilities.rb` | Shared web + MCP operation — reorder one category's capabilities (graph-validated so draft-added ones are included; shape-preserving). |
| `app/operations/operations/frameworks/set_behavioural_expectation.rb` | Shared web + MCP operation — author an expectation in an empty cell via the suggest/approve path (`suggest_create`: direct-apply with authority in editing mode, else a pending suggestion); guards against a duplicate at the same level. |
| `app/operations/operations/frameworks/rename.rb` | Shared web + MCP operation — rename the framework (shape-preserving, live; tenant admin or owner via `FrameworkPolicy#rename?`; blank rejected at the boundary, unchanged is a no-op). |
| `app/operations/operations/frameworks/{update_role_family,update_role,update_level}.rb` | Shared web + MCP operations — direct, shape-preserving org-structure renames (and role code/track, level code + entry flag for MCP). `update_level` takes `is_entry` as a `:boolean` parameter (`false` counts as supplied) under `requires_any_of :title, :code, :is_entry`. |
| `app/javascript/controllers/binding_editor_form_controller.js` | Points the binding-editor Turbo Frame at the clicked capability on `modal:open` |
| `app/javascript/controllers/frame_error_controller.js` | Shared lazy-frame failure state (error + Retry in place of a stuck "Loading…" or Turbo's "Content missing") — self-binds its five listeners in `connect()`; on the explorer it rides the binding-/level-editor modal bodies (audit issue #365) |
| `app/components/kit/frame_load_error.rb` | The hidden `role="alert"` block `frame-error` reveals — message built from `subject:` + `closeable:`, Retry, and a Close for modals |
| `app/policies/framework_policy.rb` | `edit?` (suggest bar, edit route) · `edit_structure?` / `add_capability?` / `add_category?` / `archive_capability?` / `update_role_family?` / `update_role?` / `update_level?` (edit-rights bar) · `publish?` / `define_migration_mapping?` (publish bar) · `rename?` (admin / owner — the manage-collaborators bar) |
| `app/controllers/concerns/framework_edit_mode.rb` | Reads the `framework_edit_mode` cookie → `:editing` or `:suggesting` |
| `app/operations/operations/frameworks/suggest_edit.rb` | Shared web + MCP operation — framework content edits (capability/category name + description, expectation + illustration text): authority-aware auto-approve in editing mode, pending suggestion otherwise; amends the author's pending edit on a field (→ `SuggestionAmended`) instead of stacking consecutive duplicates |
| `app/operations/operations/frameworks/{suggest_create,suggest_delete}.rb` | Shared web + MCP operations — the explicit "propose a change" endpoints (`SuggestCreate` defaults to pending, editing mode auto-applies with authority; `SuggestDelete` is always pending — the archive tools own direct-apply) |
| `app/javascript/controllers/edit_mode_toggle_controller.js` | Segmented Editing/Suggesting toggle; writes the cookie client-side and dispatches `framework-edit-mode:changed` so an open editor re-labels |
| `app/javascript/controllers/modal_controller.js` | Generic modal; opens the overlay named by `data-modal-target-id` (lone-overlay fallback), APG focus trap, `data-modal-dirty-guard` Esc confirm — hosts every root-mounted explorer overlay: the eleven structural modals plus reject-suggestion, request- and resolve-clarification, and archive-illustration (Lesson 19) |
| `app/javascript/controllers/{add_capability_form,archive_form,mapping_form,archive_category_form}_controller.js` | Prefill the shared structural modals from the `modal:open` trigger dataset (§11) |
| `test/system/framework_explorer_system_test.rb` | System tests (desktop + mobile) |
| `test/system/frameworks/edit_mode_system_test.rb` | Edit vs view mode UI differences |
| `test/system/frameworks/mobile_edit_mode_system_test.rb` | Edit mode at 375×812 vs 1400×1400 — no sideways page scroll, header controls on screen, the pane as slide-over vs inline column, reviewing from the overlay (§7) |
| `test/system/frameworks/role_tree_layout_system_test.rb` | The tree's row layout — every role/family name on ONE line at both viewports and in both modes, the hover cluster reserving no width, the pencil/solo/⋮ still reachable (§7, §11a) |
| `test/system/frameworks/matrix_sticky_offsets_system_test.rb` | Measured sticky offsets — expanded row + category band clear the header at 1/3/11 roles, both viewports, with a real pointer click on the row kebab |
| `test/system/frameworks/matrix_focus_ring_system_test.rb` | On-grid focus ring (row / cell / category band) + the pane's breadcrumb × |
| `test/system/frameworks/explorer_menu_system_test.rb` | Delegated kebab menus + the one hover-cluster rule (§11a) — ARIA, Esc/outside close, keyboard reveal, coarse-pointer collapse |
| `test/system/frameworks/write_response_system_test.rb` | The write-response contract (§11b) — a `window` marker proves no write reloads the page; toast, in-place insert/reorder, the archive modal, both viewports |
| `test/support/explorer_write_stream_assertions.rb` | `assert_write_toast` / `assert_turbo_stream_action` / `assert_no_navigation` for the controller tests |
| `test/components/kit/icon_sprite_test.rb` | Sprite symbols + the `icon` helper's `<use>` output |
| `test/system/frameworks/framework_rename_system_test.rb` | Header rename — owner renames at both viewports and sees the index follow, blank name keeps the typed text behind an inline error, editor and view mode get no pencil |
| `test/system/frameworks/inline_editor_system_test.rb` | Shared editor — keyboard, Save vs Propose per role, surfaced save errors, unsaved-change guard, no table reflow (both viewports) |
| `test/system/frameworks/explorer_context_pane_test.rb` | Focus context system tests (edit mode) |
| `test/system/frameworks/suggestion_thread_system_test.rb` | Suggestion card + thread system tests (pane + detail page) |
| `test/models/frameworks/matrix_data_builder_test.rb` | Builder unit tests (incl. text-filter scope + counts) |
| `test/components/frameworks/explorer/search_highlight_test.rb` | `<mark>` highlight concern unit tests |
| `test/models/frameworks/matrix_data_builder_mode_test.rb` | `mode:` filter unit tests |
| `test/models/frameworks/suggestion_diff_test.rb` | Inline-diff algorithm unit tests (examples, density fallback, graphemes, whitespace) |
| `test/queries/frameworks/focused_suggestions_query_test.rb` | Focus filter unit tests |
