# Assessments — File Reference

> Part of the [assessments.md](../assessments.md) guide set. Read this when: looking for the file that owns a piece of the assessment screens.

## File Reference

| File | Purpose |
|------|---------|
| **Page-level views** | |
| `app/views/assessments/show_view.rb` | Self-assessment shell — unified sticky header + main column + activity sidebar |
| `app/views/assessments/manager_show_view.rb` | Manager assessment shell — same shape, different H1 + action cluster |
| `app/views/assessments/index_view.rb` | Assessment list (own + direct reports) |
| `app/views/assessment_guides/show_view.rb` | "How assessments work" — the illustrated walk through one cycle (`/assessments/how-it-works`) |
| `app/views/assessments/status_pill.rb` | Header status pill — In Progress / N to confirm / Assessment Complete / Aligning / Aligned; Turbo-replaceable (`id="assessment-status-pill"`) |
| `app/components/shared/to_confirm_chip.rb` | The dashed amber "to confirm" chip — status pill, card name row, list cards, the hero and category links |
| `app/controllers/assessments/carried_ratings_controller.rb` | A category's carried ratings: the review page (GET) and the bulk confirm (POST → `ConfirmCarriedRatings`) |
| `app/views/assessments/carried_ratings/index_view.rb` | The review page — every carried cell ticked, with its expectation and this cycle's feedback |
| `app/operations/operations/assessments/confirm_carried_ratings.rb` | Shared web + MCP bulk confirm — checks each cell is still carried, then confirms through `RateSelf` / `RateAsManager` |
| `app/views/assessments/header_chrome.rb` | Shared header chrome for both show views — the lens control, the status pill or lens banner, the lens modal, and `lens_params` for frame srcs |
| `app/views/assessments/lens_control.rb` | The shortcode chip as the lens control — the role's ladder, "Back to E3", "Another role…" (see [*Role lens*](role-lens.md)) |
| `app/views/assessments/lens_role_modal.rb` | "Read against another role" — GET form, role by family, level kept at the reader's ordinal |
| `app/views/assessments/cycle_control.rb` | The header's cycle switcher — every cycle the person joined, a past one opening read-only with `?cycle_id=` (see [*Past cycles*](role-lens.md)) |
| `app/views/assessments/past_cycle_banner.rb` | The line that replaces the status pill on a past cycle — how it ended, how far alignment got, the way back |
| `app/views/assessments/lens_banner.rb` | The lines that replace the status pill under a lens — what it reads against, and where alignment against the lens role stands (with the manager's start) |
| `app/views/assessments/start_lens_alignment_modal.rb` | "Start alignment against PM3?" — the confirmation, a `Kit::Modal` form |
| `app/views/assessments/lens_alignment_chips.rb` | "Aligning · PM3" chips linking into each started lens role |
| `app/queries/assessments/lens_alignments.rb` | The started lens-role alignments per participation — list cards and the home page |
| `app/models/assessments/disclosure.rb` | Disclosed and frozen cells — the union of started roles' scopes (see [*Lifecycle*](lifecycle.md)) |
| `app/read_models/assessment_cycle_role_alignment.rb` | One row per role alignment has started against (home included), written by `CurrentAssessment` |
| `app/operations/operations/assessments/{start,complete,reopen}_alignment.rb` | The alignment milestones, web and MCP, per role (`AlignmentLens` resolves the role) |
| `app/contexts/person_development/async_handlers/lens_alignment_notifier.rb` | Tells the assessee when alignment against another role starts |
| `app/javascript/controllers/lens_picker_controller.js` | Rebuilds the lens modal's level select on a role change |
| `app/read_models/assessment_exploration.rb` | A declared exploration (ADR-22) — PK the event-carried id, written by `CurrentAssessment` |
| `app/queries/assessments/open_explorations.rb` | Open explorations per assessment, with target-level progress for the person's own list |
| `app/views/assessments/{start,stop}_exploration_modal.rb` | "Keep exploring this" / "Share with Alex" and "Stop exploring" dialogs (shared form in `exploration_modal_form.rb`) |
| `app/views/assessments/exploration_chips.rb` | "Exploring PM3" chips on a report's card, linking into the lens |
| `app/controllers/assessments/{explorations,exploration_closures}_controller.rb` | Declare / close from the lens banner → the shared Operations; back to the lens |
| `app/operations/operations/assessments/{start,close}_exploration.rb`, `explorations_list.rb` | Declared explorations, web and MCP (`ExplorationPayload` is the one shape) |
| `app/contexts/person_development/async_handlers/exploration_notifier.rb` | Tells the other party when an exploration starts or closes |
| **Hero summary** | |
| `app/views/assessments/hero_summary.rb` | Three-band hero card with state-driven middle band; renders inside the unified sticky header |
| `app/views/assessments/verdict_panel.rb` | The middle band's state panel: a `Kit::Card` inset with the verdict's edge and heading. The vocabulary settings preview renders it too |
| `app/views/assessments/glossary.rb` | The assessment vocabulary — built per request so every definition names the viewer's level codes, the framework's configured bands and the tenant's words; `SCALE_SENTENCE` is shared with the calibration glossary |
| `app/views/assessments/concerns/defined_terms.rb` | `defined_term(key)` — renders a scored term with its definition attached, through `Kit::DefinitionTip` (hover AND keyboard); `weight_chip` / `required_chip` — the ONE drawing of the binding chips the card, the hero gap list and the explainer share |
| `app/views/assessments/score_explainer_modal.rb` | "How is this calculated?" — the viewer's own arithmetic first, then the rules, then what doesn't count |
| `app/views/assessments/state_labels.rb` | The ONE reader of a state's word — the tenant's own if it set one, else the word Espalia ships (#415) |
| `app/operations/operations/tenants/update_scoring_vocabulary.rb` | Shared web + MCP operation — rename the performance states for a tenant (labels only; the states and thresholds are untouched) |
| `app/views/assessments/concerns/score_scale.rb` | The ONE score vocabulary every altitude reads — tone by state, state words, level codes relative to the assessed level, the band count the bar draws |
| `app/views/assessments/score_bar.rb` | The scale made visible at three sizes (`:lg` hero / `:md` category / `:sm` card) — one segment per band, tick-labelled with level codes at hero size only |
| **Category navigation** | |
| `app/views/assessments/category_chip_bar.rb` | Sticky chip row, active marker, per-category state dot + percent (both behind the coverage gate) |
| `app/views/assessments/category_indicators.rb` | A category's score at its section head — rated count, split, tone-coloured percent (state as a `title`, never a word), `:md` bar, divergent-perspective annotations |
| `app/views/assessments/category_section.rb` | Anchor target + sticky section heading + stack of capability cards |
| **Matrix content** | |
| `app/views/assessments/assessment_matrix_frame_view.rb` | Turbo Frame wrapper for the matrix |
| `app/views/assessments/assessment_matrix.rb` | Container that renders each `CategorySection` |
| `app/views/assessments/capability_card.rb` | One card per capability — eyebrow, name row, level strip, expansion panel |
| `app/views/assessments/capability_name_row.rb` | The card's name row — name, the `×N` / Required chips ([#431](https://github.com/mr-yum/growth-os/issues/431)), Blocked badge, and the capability's own score with its split (`id="capability-name-<stable_id>"`, Turbo-replaced by the rating controllers) |
| `app/views/assessments/level_strip.rb` | Horizontal flex of `LevelChip`s, scrolls horizontally on narrow |
| `app/views/assessments/level_chip.rb` | One chip per level — solid fill by frequency, diagonal split on disagreement / partial rating (colour vs grey), evidence/comment glyphs, YOU/CURRENT current-level badge |
| `app/views/assessments/capability_card_expansion.rb` | Focused-level panel — expectation sentence + inline FrequencyPill, divergent SecondaryRatingLines, illustrations, evidence, comments |
| `app/views/assessments/frequency_palette.rb` | Shared 4-state colour palette + sentence phrases for pill / chip / dot |
| `app/views/assessments/frequency_pill.rb` | Inline rating pill (interactive popover or static coloured span) |
| `app/views/assessments/secondary_rating_line.rb` | Divergent-perspective sentence with a colour-coded dot |
| `app/views/assessments/rating_error.rb` | Rating error flash partial |
| **Activity feed** | |
| `app/views/assessments/activity/feed.rb` | Right sidebar — entry list, filter chips, focus mode toggle |
| `app/views/assessments/activity/filter_chips.rb` | All / Ratings / Evidence / Comments / Alignment (wraps onto multiple lines) |
| `app/views/assessments/activity/focus_mode_toggle.rb` | Highlight / Filter segmented control |
| `app/views/assessments/activity/entry.rb` | Single entry — author, title, body, badges |
| `app/views/assessments/activity/feed_frame_view.rb` | Turbo Frame wrapper for the activity feed |
| `app/views/assessments/activity/pane_toggle.rb` | Activity button in the header — opens/closes the sidebar |
| **Delegation** | |
| `app/components/kit/modal.rb` | Reusable modal (standalone w/ trigger, or embedded); hosts the Delegates + evidence modals |
| `app/views/assessments/delegations/frame.rb` | `delegations-list` Turbo Frame — add-form + active-delegate list (revoke) |
| **Controllers** | |
| `app/controllers/assessments_controller.rb` | show / index / matrix / scoring / capability_card (one card, for a chip click) / activity — self/manager/alignment context routing; index unions delegated reports; show loads delegates |
| `app/controllers/concerns/assessments/capability_card_rendering.rb` | Reads the assessment the way the page does (lens, context, matrix data, viewer flags) and builds one card as the matrix does (`capability_card_view`) — shared by `AssessmentsController` and the comments controller |
| `app/controllers/assessments/comments_controller.rb` | Comment POST / PATCH / DELETE — a cell comment answers Turbo by replacing its thread and level chip, once the viewer can still see the assessment (Hard-Won Lesson 21); an evidence-link comment redirects within its thread frame |
| `app/controllers/assessments/delegations_controller.rb` | Grant / revoke a manager-rating delegation (Turbo Frame; dispatches `Operations::Assessments::{Delegate,Revoke}…`) |
| `app/controllers/assessments/ratings_controller.rb` | Self-rating POST (rate_self, revise, clear) |
| `app/controllers/assessments/manager_ratings_controller.rb` | Manager-rating POST (rate_as_manager, revise, clear) |
| `app/controllers/assessments/alignment_ratings_controller.rb` | Per-cell alignment POST (align_assessment) |
| `app/controllers/assessments/alignment_starts_controller.rb` | Manager-only POST — fires `AlignmentStarted`, locks individual ratings |
| `app/controllers/assessments/alignment_completions_controller.rb` | Manager-only POST — fires `FullAlignmentCompleted`, freezes all ratings |
| `app/controllers/assessments/alignment_reopenings_controller.rb` | Manager-only POST — dispatches `Operations::Assessments::ReopenAlignment`, returns the cycle to `aligning` (agreed values preserved) |
| `app/operations/operations/assessments/reopen_alignment.rb` | Shared web + MCP operation — re-open a completed alignment (manager-only, cycle still open) |
| **Notifications** | |
| `app/contexts/person_development/async_handlers/comment_notifier.rb` | Async handler: `CommentPosted` → reply / assessee / manager-side notifications (see [*Comment notifications*](evidence.md)) |
| `app/notifiers/{comment_reply,assessment_commented,team_assessment_commented}_notifier.rb` | Presentation per notification type — title, excerpted body + context line, cell deep link |
| **Data** | |
| `app/queries/assessments/role_scope.rb` | The ONE definition of the cells a role reads (ADR-22) — active bound capabilities × their expectations, plus the bindings scoring uses; every rating reader filters through it via `AssessmentLevelRating.within` |
| `lib/rubocop/cop/espalia/ratings_must_be_role_scoped.rb` | Fails CI on a rating query that never passes through `.within` or `.across_all_roles` |
| `app/models/assessments/matrix_data_builder.rb` | Single-role builder — ratings + 4 scoring perspectives + `performance_state` + next-level contributions + `current_level_complete`. Resolves the **assessed level** from the cycle's enrollment snapshot (same-role gate), not the live assignment level — see [ADR-19](../../architecture/adrs.md) |
| `app/models/assessments/secondary_perspectives.rb` | The ONE list of the perspectives shown beside the viewer's own — each carrying its context, so a secondary annotation can be held to the coverage gate against its own ratings |
| `app/models/assessments/viewer_context.rb` | The ONE `:self` / `:manager` / `:alignment` resolution — the web controller and the MCP read tools both call it, so a score can't be built from ratings the viewer may not see; a lens on another role never reads as `:alignment` |
| `app/models/assessments/lens.rb` | The role and level a page is read against, with its home (ADR-22) — resolved once per request, threaded wherever a role goes |
| `app/models/assessments/disclosure.rb` | The cells whose manager / aligned values the assessee may see — the home scope once home alignment starts |
| `app/operations/operations/assessments/rating_cell.rb` | The rating Operations' shared cell check (`as_role_id`), `via_role_id` stamp and the manager-side home-scope refusal |
| `app/operations/operations/assessments/read_lens.rb` | The MCP read tools' lens resolution and `in_role` overlay |
| `app/queries/assessments/score_summary.rb` | The MCP read tools' score payload — runs the same `MatrixDataBuilder` the web renders and reshapes its scoring into whole percents plus the scale's own meaning |
| `app/queries/assessments/level_coverage.rb` | Current-level self/manager/aligned completion for a (person, framework, cycle). Its denominator is the role scope at the assessed level, the builder's cells; consumed by the `CurrentAssessment` projection to stamp `assessment_cycle_progress.{self,manager}_completed_at` for the dual-party list status, and by the alignment-completion gate (aligned side) |
| `app/views/assessments/alignment_completion_control.rb` | Gated "Mark alignment complete" header control — disabled + "N to align →" jump chip until current-level aligned coverage is whole; Turbo-Stream-replaced on every alignment rating |
| `app/views/assessments/continue_assessing_link.rb` | Shared "jump to a capability cell" anchor — sole owner of the `continue-assessing` href/data contract (hero CTA, priming CTA, completion jump chip) |
| `app/read_models/assessment_level_rating.rb` | Three-frequency read model (self / manager / aligned) |
| `app/read_models/person_framework_assignment.rb` | Person-framework-role-level assignment |
| `app/read_models/recorded_reporting_manager.rb` | Recorded reporting manager — authoritative for manager-rating authority |
| `app/read_models/manager_assessment_delegation.rb` | Active/revoked rating delegations; `active` scope + `candidate_people` |
| **JavaScript** | |
| `app/javascript/controllers/matrix_controller.js` | Chip-click focus, smooth-scroll, URL sync, sibling dimming (shared with framework explorer) |
| `app/javascript/controllers/category_nav_controller.js` | `--sticky-header-h` publish, chip-click scroll, active-chip detection on scroll |
| `app/javascript/controllers/assessment_sync_controller.js` | ActionCable sync, self-submit suppression, dual-frame reload, focus-param merge |
| `app/javascript/controllers/activity_feed_controller.js` | Focus-narrowing on `matrix:focus-changed` |
| `app/javascript/controllers/continue_assessing_controller.js` | Bottom-line CTA — dispatches focus-unrated event |
| `app/javascript/controllers/modal_controller.js` | Generic `Kit::Modal` open/close/Esc; opt-in outside-click dismissal (`dismissOnOutsideClick`, default off); dispatches `modal:open` |
| `app/components/kit/modal.rb` | The panel is capped at `max-h-[90dvh]` with a pinned header and a scrolling body — a modal taller than the viewport used to centre and push its own title and × off the top edge, leaving Esc as the only exit and nothing on screen saying so |
| `app/javascript/controllers/evidence_modal_controller.js` | Drives the unified evidence modal — frame `load`, link rows, type toggle (shared with the hub) |
| `app/javascript/controllers/frame_error_controller.js` | Shared lazy-frame failure state — error + Retry in place of a stuck "Loading…" (see the controllers table) |
| `app/components/shared/frame_load_error.rb` | The hidden `role="alert"` block `frame-error` reveals — Retry, plus an optional Close for modals (whose own ×/Cancel went down with the hidden frame). Callers pass `subject:` ("the form", "the discussion") and the sentence — including whether its tail says "close this" — is built from `subject:` + `closeable:`, so the copy can't promise an exit the site doesn't render. Owns `BUTTON_CLASSES`, the canonical secondary-button treatment the evidence forms' `SECONDARY_BTN` point at |
| **Unified evidence modal** (one modal for new/edit/respond, assessment + hub) | |
| `app/views/evidence/modal_form.rb` | The form rendered into the `#evidence-modal` frame — writing-prompt card (:new/:respond only; role/level line only off the hub), content fields (disabled for a non-author link), and the unified **"Applies to" block**: uniform per-link rows (expectation + required-on-new valence + collapsible examples; entry-point row first + highlighted; last-row remove lock, lifted when the item may stay unplaced) + the capability/level picker (see [*The unified "Applies to" block*](evidence.md)) |
| `app/views/evidence/recipient_picker_form.rb` / `recipient_row.rb` / `recipient_candidates_frame.rb` | The "Give feedback" step: who is it for? Suggestions + typeahead over the recipient directory; each row navigates the `evidence-modal` frame to the `:new` form (see [*Proactive feedback*](evidence.md)) |
| `app/views/assessments/unplaced_feedback_notice.rb` | "N pieces of feedback about you are waiting to be placed" on the assessment, linking to the page's "Needs you" |
| **The Feedback / Evidence page** (`/evidence`, conversations — see [*The Feedback / Evidence page*](evidence.md)) | |
| `app/queries/evidence/conversations.rb` | What the viewer sees, grouped into conversations by the four-clause rule, per person or per report; what each message owes |
| `app/models/evidence/conversation_reads.rb` | Unread messages, read from the notifications we already send; marks a thread's read |
| `app/controllers/evidence_hub_controller.rb` | The page, a thread by its URL (`/evidence/with/…`, `/evidence/about/…`), and the `/evidence/items/…` / `/evidence/requests/…` links that land on a message's thread |
| `app/controllers/concerns/evidence_hub_return.rb` | Sends a write started on the page back to the thread it came from |
| `app/views/evidence/hub_view.rb` / `needs_you.rb` / `conversation_list.rb` / `conversation_thread.rb` / `conversation_message.rb` / `conversation_chrome.rb` | The page, "Needs you", the list with its attention dots, the open thread and composer, one message (every respond / decline / nudge / cancel / place / edit / withdraw action), and their shared helpers |
| `app/views/evidence/request_cell_step.rb` | The request modal's first step when it opens without a cell: pick the capability and level |
| `app/javascript/controllers/conversation_thread_controller.js` / `conversation_search_controller.js` | Opens a thread on its newest message; filters the list by name |
| `app/javascript/controllers/evidence_hub_controller.js` | Clicks "Give feedback" on arrival when the URL carries `?give=1`, and follows an old `#evidence-item-…` anchor to its thread |
| `app/views/evidence/valence.rb` | Shared valence surface vocabulary — UI labels + badge styling for `EvidenceLink::VALENCES` (see [*Evidence-link valence*](evidence.md)) |
| `app/views/assessments/evidence/link_thread_frame.rb` | One linkage's discussion thread (lazy frame in the evidence card's disclosure) — lifecycle rows + comment cards + composer + removed/withdrawn notices (see [*Evidence-linkage discussion threads*](evidence.md)) |
| `app/queries/assessments/evidence_link_thread_query.rb` | Assembles a linkage thread — comments + stream-read lifecycle entries (linked / revalenced / removed / withdrawn) |
| `app/controllers/assessments/evidence_link_threads_controller.rb` | `GET /assessments/:id/evidence/:evidence_id/link_thread` — serves the thread frame (comment-policy gated) |
| `app/operations/operations/assessments/set_evidence_link_valence.rb` | Shared web + MCP operation — reclassify one link's valence (`EvidenceLinkRevalenced`; no-op when unchanged) |
| `app/views/evidence/modal_shell.rb` | The bare overlay/panel + lazy `#evidence-modal` frame (plus its `Shared::FrameLoadError` load-failure state), hosted inside `assessment-sync` (so the submit updates the matrix in place) |
| `app/views/evidence/request_modal_shell.rb` | The request-evidence overlay/panel + lazy `#evidence-request-modal` frame + its `Shared::FrameLoadError` state — the modal's own × lives inside the frame, so a failed load without this has no exit at all. Also carries `submit-fallback` + its live region for a transport failure on Send (#316) |
| `app/javascript/controllers/submit_guard_controller.js` | One user action, one request — in-flight lock on the evidence-modal **and request-evidence** submit buttons (see the controllers table) |
| `app/controllers/evidence_modal_controller.rb` | `GET /evidence_modal` — renders `ModalForm` for `(mode, evidence?, request?, cell?)`; resolves permissions + prefill + link options server-side; edit mode loads ALL active links (origin included, entry-point cell first) |
| `app/models/evidence/cell_context_resolver.rb` | Shared per-cell context (name, role, level title, expectation, illustrations) — hub + modal |
| **Placement suggestions** (see [*Suggested placement and valence*](evidence.md)) | |
| `app/models/evidence_placement_suggestion.rb` | One suggested cell + valence for an item, pending until a person decides; plain state, not a read model |
| `app/models/evidence/placement_prompt.rb` | The candidate cells (role cells at the home level ±1, minus linked and dismissed), the cached framework text, the item text and the enum-constrained schema; `VERSION` is recorded on every row |
| `app/models/evidence/suggestion_model.rb` | The one model call: pseudonymises, asks the tenant's adapter (a chat prompt, or Jev's decision questions), maps `Ai::Errors` to `RateLimited` / `Unavailable` / `Rejected`; a refusal is no suggestions |
| `app/models/evidence/placement_decision.rb` | What Jev is asked: the state, a choice over the open cells plus `none`, a choice over the valences; ranks the answer by probability above `FLOOR`; its own `VERSION` |
| `app/integrations/ai/` (`model_client.rb`, `anthropic/adapter.rb`, `open_ai_compatible/adapter.rb`, `typesafe_jev/adapter.rb`, `json_endpoint.rb`, `suggestion_response.rb`, `decision_response.rb`, `errors.rb`, `endpoint.rb`, `name_pseudonymiser.rb`) | The tenant's model: adapter dispatch, the three adapters and their shared HTTP half, the chat and decision responses, the errors, the private-host guard, name hiding |
| `app/models/ai_model_config.rb` / `ai_model_credentials.rb` | `Tenant.ai_config` (provider, address, model, effort, switches, presets) and the write-only key wrapper |
| `app/controllers/tenant/ai_models_controller.rb` / `app/views/integrations/ai_model_view.rb` / `app/javascript/controllers/ai_model_preset_controller.js` | The Integrations → AI model card: settings, key, test connection, preset fill |
| `app/jobs/evidence/suggest_placements_job.rb` | Generates a set: supersedes the pending one, re-validates every cell, stores the rest; `after_generate` is the notification hook |
| `app/contexts/person_development/async_handlers/placement_suggester.rb` | Async handler on `EvidenceRecorded` / `EvidenceUpdated` that enqueues the job for human-authored feedback, self feedback included, when the tenant switch is on |
| `app/views/evidence/placement_suggestions.rb` / `placement_suggestion_status.rb` | The block under an item in a conversation (rows, Accept, Dismiss…, Adjust, Suggest again) and the status line its responses write into |
| `app/models/evidence/self_feedback_backfill.rb` / `lib/tasks/evidence_suggestions.rake` (`backfill_self`) | The manual backfill for self feedback recorded before it got suggestions: a dry run unless `CONFIRM=1`, paced `PER_MINUTE` |
| `app/controllers/evidence_placement_suggestions_controller.rb` | Accept / dismiss / suggest again → Turbo Stream replacing the block |
| `app/models/evidence/placement_suggestion_rows.rb` | Loads the pending rows and their cell context for a set of hub items |
| `lib/tasks/evidence_suggestions.rake` / `evidence_suggestions_eval.rb` | `evidence:suggestions:eval[slug]` — cell and valence match rates against `test/fixtures/files/evidence_suggestions/`, through the tenant's configured model |
| `app/models/evidence/framework_cell_options.rb` | Valid (active + bound + has-expectation) link cells + the per-cell expectation map (incl. role-scoped illustrations) for the "Applies to" rows |
| `app/controllers/concerns/evidence_diff_submit.rb` | Diff-based save — emits the minimal commands (record / update-if-content-changed / add+remove links / respond); links-only never bumps `edited_at` |
| `app/controllers/assessments/evidence_controller.rb#save` | Assessment-surface submit → matrix cell Turbo Streams (hub uses `evidence_requests#respond` / `evidence_items#update`) |
| **CSS** | |
| `app/assets/tailwind/application.css` | `.hero-collapsible` scroll-driven animation (`animation-timeline: scroll(root)`) + `.assessment-scroll-root` anti-shake guard (`overflow-anchor: none` + `min-height` floor — Hard-Won Lesson 16) |
| **Tests** | |
| `test/system/assessments_system_test.rb` | Self-assessment system tests |
| `test/system/manager_assessments_system_test.rb` | Manager assessment system tests |
| `test/system/assessments_activity_feed_focus_system_test.rb` | Activity feed narrows on focus |
| `test/system/assessments_activity_pane_system_test.rb` | Sidebar open/close + responsive behaviour |
| `test/contexts/person_development/scoring_test.rb` | The level-independent scale (ADR-21): components, the per-binding gate, cap window, expectation coverage, `performance_state` transitions |
| `test/components/assessments/hero_summary_test.rb` | Hero copy per state (top of ladder, mastering, blocked, eligible), the components gloss, the 0–200 / 0–100 bar |
| `test/models/assessments/matrix_data_builder_test.rb` | Data shape + `capability_scores_at_next_level` presence |
| `test/system/assessment_delegation_system_test.rb` | Manager grants via modal → delegate reviews + rates → can't start alignment |
| `test/policies/assessment_policy_delegation_test.rb` | Delegate rating, recorded-authoritative manager, grant/revoke gates |
| `test/contexts/person_development/aggregate_authority_test.rb` | Reporting-manager recording, delegation commands, authority guard, `via_delegation` |
| `test/queries/assessments/activity_feed_authority_test.rb` | Delegation/reporting entries, badge, privacy + delegate visibility |
