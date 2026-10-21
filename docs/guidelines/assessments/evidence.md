# Assessments — Feedback / Evidence

> Part of the [assessments.md](../assessments.md) guide set. Read this when: changing evidence recording, linking, valence, linkage threads, the evidence modal, proactive feedback, placement suggestions, requesting evidence, or comment notifications.

## Evidence-link valence — "what does this say about the behaviour?"

Every evidence link carries a **valence** — the linker's judgment of what the
evidence says about the behaviour at that capability × level — on a 4-point
forced-choice scale (no neutral midpoint, mirroring the frequency vocabulary):

| Event value (frozen forever) | UI label (changeable) |
|---|---|
| `strongly_demonstrated` | Strongly demonstrates |
| `demonstrated` | Demonstrates |
| `growth_area` | Growth area |
| `significant_growth_area` | Significant growth area |

Design rules — all deliberate, don't relitigate piecemeal:

- **Valence lives on the LINK, not the item.** One piece of feedback can be
  positive evidence for one behaviour and constructive for another.
  `EvidenceLink.valence` is asserted by whoever creates that link
  (`linked_by_id`) — including a non-author link editor.
- **Required on every NEW link; never retro-forced.** The aggregate
  (`record_evidence` / `add_evidence_link`), the Operations, and the modal's
  `required` controls all demand it. Links created before valence existed stay
  nil forever (events are immutable; intent can't be backfilled) and pass
  through content edits untouched — no backfill-by-attrition. Reclassifying is
  an explicit affordance (the link row's select in the edit modal / the
  `assessments_set_evidence_link_valence` tool) emitting
  `EvidenceLinkRevalenced`: link identity and `linked_at` preserved, no
  `edited_at` bump, silent no-op when unchanged.
- **NOT a scoring input.** ADR-10 stands: valence is narrative metadata for
  the rater and the alignment conversation. Nothing in
  `PersonDevelopment::Scoring` reads it, and nothing should without an ADR.
- **Surface vocabulary** lives in `Views::Evidence::Valence` (labels + badge
  classes). Badges use emerald / amber / rose tints — never the frequency
  palette (red/yellow/green/blue means *ratings*) — and the text label is
  always present; colour is reinforcement, never the sole signal. Badges
  render per-cell on the expansion panel's evidence cards (the same item can
  read "Demonstrates" in one cell and "Growth area" in another, via the
  transient `EvidenceItem#link_valences` map) and on the hub response cards'
  "Applies to" chips.
- **Modal UX**: one shared valence dropdown (`ModalForm#valence_select`;
  surface term is "valence", never "judgment"), rendered per **"Applies to"
  row** — every linked behaviour carries its own (see *The unified "Applies
  to" block* below). The block sits after "What happened?" (hierarchy: what
  happened, then what it says, per behaviour; deliberately no default). On
  :new/:respond the seeded origin row's valence is **required** (id
  `evm-valence`); JS-staged rows carry their own required select (blank
  "Valence…" placeholder blocks submit until chosen — mandatory for every
  new link without overloading the add). In edit mode a pre-valence (nil)
  link renders an optional "Valence…" placeholder; a classified link can be
  re-classified but not cleared. Per-link valences submit as
  `evidence[link_valences][<cap>|<level>]` alongside the untouched
  `desired_links[]` tokens; `EvidenceDiffSubmit` validates every new link's
  valence BEFORE any write, then derives add-with-valence / revalence
  deltas from the map.
- **Feed coverage**: `evidence_linked` entries carry the valence label on the
  secondary line; reclassifications are their own `evidence_revalenced` kind
  ("Growth area (was Demonstrates)"), evidence group, anchored to the cell.
- **MCP parity**: `assessments_record_evidence` /
  `assessments_add_evidence_link` / `assessments_respond_to_evidence_request`
  take a required `valence` enum (each `additional_links` entry carries its
  own); `assessments_set_evidence_link_valence` reclassifies. Read payloads
  include `valence` per link (nil = pre-valence link).

## Evidence-linkage discussion threads

Every evidence **linkage** — one (evidence_id × capability_stable_id ×
level_ordinal) cell an item is linked to — carries its own discussion
thread, so the manager and assessee can debate *that linkage and its
valence* rather than the item in general. Design rules, all deliberate:

- **Anchored to the linkage's natural key, not the `EvidenceLink` row.**
  The thread survives valence reclassification (the discussion usually
  *causes* it), link removal, and re-add (same key ⇒ the history
  reattaches). Data model: `commentable_type: "evidence_link"` on
  `PersonDevelopmentComment` + an `evidence_id` column — same events,
  projection (`CommentThread`), threading model, and `comments-thread`
  Stimulus contract as cell comments; comment rows reuse
  `Views::Assessments::Comments::Card` verbatim.
- **Surface**: a collapsed count-plus-excerpt disclosure on each evidence
  card (per cell — the same item carries an independent thread in every
  cell it's linked to). A native `<details>` hosts a `loading: "lazy"`
  turbo frame, so the thread is fetched only when opened.
- **Lifecycle rows interleave with comments.** The thread renders the
  linkage's story — *linked as «valence»*, *valence changed*, *removed*,
  *withdrawn* — as muted system rows (hollow dot, italic, no kebab/reply)
  read from the PD stream by `Assessments::EvidenceLinkThreadQuery`
  (stream reads stay off the matrix render path; only the lazy frame
  pays them).
- **Removal keeps the thread open**: the removal is often the
  discussion's outcome, so the composer stays under a "no longer linked"
  notice (the aggregate accepts any linkage that *ever* existed).
  **Withdrawal makes it read-only** (the artifact itself is retracted;
  aggregate-enforced). Both removal surfaces (card kebab unlink confirm,
  modal "Applies to" row) disclose an active thread's comment count and
  that it is preserved.
- **Participants = the assessment-side comment set** (assessee + manager
  chain + active delegate + tenant admin — `PersonDevelopmentCommentPolicy`
  verbatim). The **evidence author (a peer) is deliberately excluded**;
  the hub deliberately shows no thread counts so it doesn't tease a
  conversation the author can't open. No pre-alignment gate beyond what
  cell comments already accept.
- **Feed**: posts surface as `evidence_link_commented` entries (comments
  chip, cell-anchored, naming whose feedback is discussed); linkage
  comments also count toward the level chip's comment glyph. Live via
  `CommentThread`'s existing broadcast.
- **Writes** go through the same comments endpoints
  (`Assessments::CommentsController`; `comment[evidence_id]` selects the
  type) with frame-scoped redirects; MCP parity via an `evidence_id`
  param on `assessments_post_comment` / `assessments_comments_list`.

## The unified "Applies to" block (evidence modal)

The modal used to treat the "primary" linkage (a top context card + its own
valence field) and the "Also applies to" extras as two separate surfaces —
disorienting when Edit was opened from a *secondary* cell, because the card
at the top named a different behaviour than the one clicked. The linkage UI
is now **one "Applies to" block**: every behaviour the feedback is linked to
renders as a uniform row — capability · level (with the role's level title),
the behavioural expectation, that link's valence dropdown, and a collapsible
**Examples** disclosure (role illustrations) — plus the capability/level
picker at the block's foot.

Rules — all deliberate:

- **The origin cell is a creation fact, not a protected link.** The
  `record_evidence` origin (`EvidenceItem.capability_stable_id`/`level_ordinal`)
  stays immutable event history, but the UI never singles it out: in edit
  mode ALL active links render as removable rows, the origin included (the
  aggregate already allowed removing it — the only invariant is "an active
  item keeps ≥ 1 link"). The edit form submits **no `primary_cell`**;
  `EvidenceDiffSubmit#diff_edit` diffs desired vs current links. Removing
  the last remaining row is locked client-side (× disabled, "withdraw it
  instead") with the aggregate as backstop.
- **The entry point orients the modal.** The card's Edit trigger passes the
  cell it sits in (`capability_stable_id` + `level_ordinal` params); that
  row sorts first, gets a primary ring + tooltip ("You opened this feedback
  from here"), and its Examples render pre-expanded. Hub-opened edits carry
  no entry cell — rows keep `linked_at` order.
- **:new / :respond seed the block** with a fixed (non-removable) origin row
  carrying the REQUIRED valence — it anchors `record_evidence` / the
  request's cell, so `evidence[primary_cell]` still submits in these modes.
  These two modes also keep a **writing-prompt card** above the content
  fields (capability · level, "What good looks like", examples behind a
  disclosure) — when composing, the behaviour being written about belongs
  above the textarea. Edit mode renders no top card; hub-opened edits get a
  one-line "Feedback on ⟨name⟩'s assessment · ⟨role⟩" scope line instead
  (the hub lists items across people).
- **Examples come from the embedded map.** `FrameworkCellOptions#expectation_map`
  carries role-scoped `illustrations` per valid cell, so server-rendered and
  JS-staged rows render the same disclosure without extra fetches.

## Proactive feedback — anyone, on anyone, placed or not

Feedback does not have to be asked for. `EvidencePolicy#create?` has always
admitted any member with a Person record, so a peer could record feedback on
any colleague with a framework assignment; what was missing was the way in,
and the way to say it without knowing the framework
([#502](https://github.com/mr-yum/growth-os/issues/502)). Three pieces, all
shared by web, MCP and Slack:

- **The recipient directory.** `Assessments::FeedbackRecipients` finds people
  with an assignment by name or email, or offers the giver's manager, peers
  and reports when there is no query, one row per assignment, each with the
  giver's relationship (`report` / `manager` / `peer`). It is the only read a
  peer has: `AssessmentPolicy#show?` still denies them the assessment page,
  and `assessments_mine` lists only what the caller owns or reviews. Web and
  MCP (`assessments_feedback_recipients`) share it.
- **Unplaced items.** An item recorded with no capability × level has no
  origin cell and no links (`EvidenceItem.unplaced`): a colleague knows what
  happened but not which expectation it speaks to. The recipient, their
  manager chain, an active delegate or the author places it through the
  ordinary add-link path (`EvidencePolicy#add_link?`); until then it appears
  on the hub and in the activity feed as a framework-scoped entry ("gave
  feedback, not yet placed on a capability"), never in a cell and never in a
  score. The first placement becomes the item's origin cell, so the feed,
  the hub and the reporting joins read a placed-later item like any other.
  The last-link rule protects a *placed* item only: an unplaced item
  has nothing to remove, and its first link puts it under the rule. The
  aggregate refuses half a cell, a valence with no cell, and additional
  links with no first link. `EvidenceRecorded` carries nil coordinates for
  the new shape; every historical event has a cell, so the projection needed
  no `CODE_VERSION` bump.
- **The recipient is told.** `PersonDevelopment::AsyncHandlers::FeedbackNotifier`
  turns `EvidenceRecorded` into `feedback_received` (the recipient) and
  `team_feedback_received` (the recorded reporting manager plus active
  delegates), in-app and Slack by default. Never the author, never for self
  feedback, and not the requester of a request the item answers — that
  requester already gets "answered" (see *Reminders and nudges*; the
  handler also skips anyone with a request to the author still pending, in
  case the response is projected a moment after the item, on the same
  cell). An unplaced item's copy asks the recipient to place it and links to
  its card on the hub (`EvidenceItem.hub_path`); a placed one links to its
  cell.
  Both notifiers share `AssessmentNotificationRecipients` with the comment
  notifier (manager side, dedup on retry, provisioning a never-signed-in
  recipient).

**On the web** ([#503](https://github.com/mr-yum/growth-os/issues/503)):

- **"Give feedback"** on the hub header (and "Give feedback →" on the Home
  card, which opens it on arrival via `?give=1` and the `evidence-hub`
  controller). The unified evidence modal opens on a first step — `mode=give`,
  `Views::Evidence::RecipientPickerForm`: the directory's suggestions plus a
  debounced search (`GET /evidence_modal/recipients`, reusing the
  `person-picker` controller's typeahead only). Each row is a link targeting
  the `evidence-modal` frame, so picking someone swaps in the `:new` form for
  their assignment without the modal closing. That form has no seed cell: it
  says who it is for, carries the same visibility note the respond form
  shows, and its "Applies to" block may be left empty
  (`data-evidence-modal-allow-unplaced-value`, which also lifts the
  last-row lock). `EvidenceItemsController#create` runs the usual diff; the
  first staged row leads, or the item is recorded unplaced.
- **"Feedback to place"** on the hub: items about the viewer and, for the
  manager side (`Person#all_reports` plus active delegations), about their
  reports, each with "Place on a capability" — the edit modal with an empty
  block, content disabled for a non-author. Cards are anchored
  `evidence-item-<id>` (`EvidenceItem.hub_path`), where the unplaced
  notification lands. The assessment page shows
  `Views::Assessments::UnplacedFeedbackNotice` to viewers who see all its
  evidence, linking to that section.

**From another feedback system** ([#534](https://github.com/mr-yum/growth-os/issues/534)):
feedback given in a peer such as Chip arrives through the feedback exchange
([feedback-exchange.md](../feedback-exchange.md)) as unplaced feedback written
as its real author, dated by when it was given.

- **"via Chip" says where it came from.** `Views::Evidence::OriginBadge`
  renders on the evidence card, the hub card and the activity entry for an
  item whose `external_reference.imported?` (the importer is the only writer
  of `metadata.given_at`), named through `Reporting::OriginLabels` and linking
  to the original. It replaces the plain reference chip on those items. It is
  neutral grey on purpose: colour beside feedback already means a rating or a
  valence.
- **An import is silent.** The system the feedback was given in owns its
  notifications, so GrowthOS sends nothing for an imported item: not the
  arrival, not a request to place it. `FeedbackNotifier` returns early for
  every `acting_via: feedback_exchange` event, whatever the record's
  `notified` says (that list stays in `external_reference.metadata` as part
  of the record).
- **The hub is where it surfaces.** An imported item is unplaced, so it waits
  under "Feedback to place" for the recipient and the manager side, and the
  assessment shows `UnplacedFeedbackNotice`. Placement suggestions
  ([#558](https://github.com/mr-yum/growth-os/pull/558)), once enabled, appear
  on the same cards.
- **Its author edits the text, not where it was given.** The edit modal shows
  the badge in place of the reference fields, and `EvidenceDiffSubmit` keeps
  the imported reference on save.

**From Slack** ([#504](https://github.com/mr-yum/growth-os/issues/504)):
`/growthos feedback` and the "Feedback on this message" shortcut open a
modal that records through the same Operation, placed at the recipient's
current level or unplaced; a giver who has never signed in gets a draft link
that opens the hub's modal prefilled after sign-in. See
[slack-integration.md](../slack-integration.md).

## Suggested placement and valence

Feedback written by someone who never saw the framework arrives unplaced, or
placed on one cell when it speaks to three. When a tenant switches it on,
a model reads each new piece of feedback and suggests where it belongs; a
person decides ([#536](https://github.com/mr-yum/growth-os/issues/536), plan
§7 in [feedback-integration-plan.md](../../notes/feedback-integration-plan.md)).
Rules, all deliberate:

- **Off until the tenant chooses a model and switches it on.**
  `Tenant.ai_config` → `suggestions_enabled` (`Tenant#evidence_suggestions_enabled?`)
  gates the handler, the job and "Suggest again"; seeds never set it. Without
  a complete model config and a stored key (`Evidence::SuggestionModel.configured?(tenant)`)
  the job is a no-op too, so a tenant with no config runs nothing. Sending
  feedback text to a model provider is plan decision D2, and it is each
  tenant's own: the AI model card is where they take it. A tenant switched on
  under the earlier `Tenant.settings` key (`evidence_suggestions_enabled`,
  `evidence_suggestions_model`) stays on, on the deployment's Anthropic key,
  until an admin saves the card; saving drops the old keys. That reader
  (`Tenant#legacy_evidence_suggestions_enabled?` and the key fallback in
  `Tenant#ai_api_key`) is for one release: delete it once every tenant has
  been saved through the card.
- **Only human feedback about someone else.** The async handler
  `PlacementSuggester` enqueues `Evidence::SuggestPlacementsJob` on
  `EvidenceRecorded` and on `EvidenceUpdated`, skipping `source: "self"` and
  events whose `acting_via` is `hris` or `system`. An edit supersedes the
  pending set. It is never a projection: replaying it would re-ask the model
  about every item ever recorded.
- **The model can only answer with cells that exist.**
  `Evidence::PlacementPrompt` takes the recipient's role cells from
  `FrameworkCellOptions#expectation_map` at their level and one either side,
  and the structured-output schema makes `capability_stable_id` and
  `level_ordinal` enums of those values. The job still re-checks each pair,
  and drops cells already linked or ever dismissed for the item, so a
  dismissed suggestion never comes back. Up to three survive.
- **The framework text is the cached prefix.** Instructions plus the role's
  cells are identical for everyone at a role and level and carry the
  `cache_control` breakpoint; the feedback, who gave it and the cells to
  leave out are the volatile tail.
- **The tenant's model answers, through one class.**
  `Evidence::SuggestionModel#suggest` is the one method the job calls and the
  one tests stub. It builds the request from the prompt, asks the adapter
  `Ai::ModelClient.for(tenant)` picks, and turns the answer into at most
  three `Proposal`s. Two adapters live under `app/integrations/ai/`:
  `Ai::Anthropic::Adapter` (the official gem; the Anthropic API, or any
  Anthropic-compatible endpoint through `base_url:`; `cache_control` on the
  system text, `output_config.format` for the schema, the tenant's `effort`,
  default `low`, adaptive thinking left on) and `Ai::OpenAiCompatible::Adapter`
  (Faraday, `POST {base_url}/chat/completions`, a strict `json_schema`
  `response_format`, `Authorization: Bearer`). Both return one
  `Ai::SuggestionResponse` and raise the shared `Ai::Errors`. The stored
  config (`AiModelConfig`: `provider`, `base_url`, `model`, `effort`) is
  generic: "Vercel AI Gateway" is only a preset in the form that fills
  `openai_compatible` and `https://ai-gateway.vercel.sh/v1`, and no adapter
  special-cases it. The tenant's key is passed to the gem explicitly, so an
  `ANTHROPIC_API_KEY` in the environment never answers for a tenant.
  `Evidence::SuggestionModel` maps the errors to its own: `RateLimited`
  and `Unavailable` (5xx, no answer, a malformed one) retry with backoff;
  `Rejected` (a refused key or any other 4xx) is logged and dropped. A
  refusal, a truncated answer or unparseable JSON is simply no suggestions.
  No refusal fallback is sent on either adapter: it would route personal
  feedback to a second model nobody chose. Both adapters share the prompt,
  the candidate list, the schema and the server-side re-check in the job: a
  model that answers with an id outside the candidates yields no suggestion
  for that row. The Ruby gem spells two request keys with a trailing
  underscore, `system_:` and `output_config: { format_: … }`, because
  `system` and `format` are Ruby methods; it sends them as `system` and
  `format`. `anthropic` endpoints take the address without `/v1`, which the
  gem appends; `openai_compatible` ones take it with whatever prefix serves
  `/chat/completions`. The Anthropic gem follows redirects and resends the body, so with an
  address set a middleware (`Ai::Anthropic::Adapter::GUARD_REDIRECTS`) puts every
  leg through `Ai::Endpoint` (the exchange's `FeedbackExchange::HostGuard`);
  Faraday never follows one. The OpenAI-compatible
  adapter sends `max_tokens`, or `max_completion_tokens` for `api.openai.com`
  and OpenAI's reasoning model families (`o3…`, `gpt-5…`), which reject the
  old name.
- **Names stay home by default.** `Ai::NamePseudonymiser` swaps every person
  in the tenant for `Person N` in both texts before they leave, and swaps them
  back in the rationales that return. Whole words only, longest first, so
  "Anna" is not found inside "Annabel"; a first name only one person has
  stands for that person, and one two people share gets a placeholder of its
  own. The number is the person's rank by id, so a placeholder is the same on
  every request and the cached framework text stays cacheable. The framework
  text gets full names only, because a first name can be an ordinary word
  (Will, Mark, Grace) and would rewrite "will deliver" into "Person 7 deliver";
  the feedback gets first names too, and only the names whose first word a
  text contains are compiled into its pattern, so thousands of people cost a
  lookup per word. The mapping lives in the instance for one request and is
  not stored. It hides names, not
  roles, projects or the story; a tenant can turn it off (`pseudonymise_names`).
  Test connection sends no names; the eval runs the same path as production.
- **Admin: the AI model card.** Integrations → AI model
  (`Tenant::AiModelsController`, `IntegrationsPolicy#update_ai_model?` /
  `#test_ai_model?`, tenant admins). A preset or the generic fields, a
  write-only key (stored encrypted in `Tenant.ai_credentials`, never rendered;
  blank keeps it), the two switches, and **Test connection**, which sends the
  saved model one line and shows its reply or the failure, never the
  endpoint's body. The address is https only outside development, with no
  login, query or private-network host: `FeedbackExchange::HostGuard` through
  `Ai::Endpoint.vet!`, which also refuses `127.1` and `2130706433` (loopback to
  the system resolver, nothing to Ruby's `IPAddr`) and checks every resolved
  address at call time. The Faraday adapter then connects to the accepted
  address; the Anthropic gem cannot pin, so it is checked per request and
  redirect leg only.
  `Tenant#update_ai_model!` refuses a save that would send a stored key to a
  different provider or address without the key entered again, and one that
  switches suggestions on with no key: both would otherwise fail silently
  later. Effort "Don't send" is for models that reject the parameter (Claude
  Haiku 4.5, say). Writes are web-only; the MCP surface is the read-only
  `integrations_ai_model_status`.
- **Suggestions are state, decisions are events.** `EvidencePlacementSuggestion`
  is a plain tenant table, one row per item × cell, recording provider, model,
  prompt version and confidence. Accepting goes through
  `Operations::Assessments::AcceptEvidenceSuggestion`, which publishes
  `EvidenceLinkAdded` — or `EvidenceLinkRevalenced` when someone linked the
  cell meanwhile — carrying `via_suggestion_id`. The feed's secondary line
  then says "from a suggestion". Dismissals keep an optional reason and are
  not feed entries.
- **Who decides: `EvidencePolicy#add_link?`** — the recipient, their manager
  chain, a rating delegate and the author. Plan decision D5 may narrow it to
  the manager side.
- **On the hub, in place.** Each item the viewer may place shows its pending
  suggestions — capability · level, the valence badge, "82% confident" as
  text, the expectation and the quoted rationale — on "Feedback to place",
  "Feedback you've provided", the responses you asked for, and a "May fit
  elsewhere too" group for placed items about you or your reports with more
  cells to go (a different name from the block's own "Suggested placements"
  heading, so the page doesn't say it twice). Accept and Dismiss answer with a Turbo Stream that replaces
  `evidence-suggestions-<id>` and writes the outcome into the persistent
  `role="status"` line beside it; nothing reloads. "Adjust in the editor"
  opens the evidence modal with every pending suggestion staged as an
  "Applies to" row (`suggestions=pending`, valence preselected, "Suggested —
  rationale" note); on save a kept row is accepted and recorded as
  **edited**, and a removed one dismissed ("Removed while adjusting"). The
  staged cells are checked against the role before any write, so a cell the
  framework dropped refuses the whole save rather than half of it. Accept
  outside the editor records **accepted**, or **edited** when the person
  chose a different valence. "Suggest again" enqueues at most one run per
  item a minute: every run is a paid model call.
- **One run per item at a time.** The job takes a Postgres advisory lock on
  the item before superseding and storing, and stores nothing if the
  feedback was edited while the model answered; the edit's own run follows.
- **Notification hook.** `SuggestPlacementsJob#after_generate(item)` runs
  after each stored set and is empty; the placement notifier
  ([#534](https://github.com/mr-yum/growth-os/issues/534)) hooks in there.
- **Eval before widening.** `bin/rails "evidence:suggestions:eval[<tenant slug>]"`
  scores the current `PlacementPrompt::VERSION` against thirty invented,
  hand-placed items in `test/fixtures/files/evidence_suggestions/` (cell match
  for the top and any suggestion, valence match on hit cells, precision, and
  feedback the framework doesn't cover left alone), through the model that
  tenant has configured: its adapter, effort and name hiding, so a gateway
  model is scored the way it will answer. `MODEL=…` tries another model id on
  the same endpoint. The tenant is only read. `SUGGESTION_MODEL=baseline`
  scores a word-overlap baseline with no tenant and no call. Bump `VERSION`
  whenever the instructions, framework text or schema change, and rerun.

## Requesting evidence (cell-scoped)

A manager (or the assessee, or an active rating delegate, or a tenant admin —
`EvidenceRequestPolicy#request?`) can **ask a colleague for evidence on a specific
capability × level**. The whole flow is cell-scoped: it originates from a cell and
the response lands pre-linked to it.

- **Entry point** — a per-cell **"Request evidence"** button on the capability-card
  expansion ([capability_card_expansion.rb](../../../app/views/assessments/capability_card_expansion.rb),
  `#request_evidence_section`), next to "Add evidence". Gated on
  `can_request_evidence`, threaded from `AssessmentsController#viewer_can_request_evidence?`
  through the card view chain exactly like `can_create_evidence`.
- **The modal** ([Views::Evidence::RequestForm](../../../app/views/evidence/request_form.rb),
  hosted once via [RequestModalShell](../../../app/views/evidence/request_modal_shell.rb))
  carries the cell context (capability · level + behavioural expectation, via
  `CellContextResolver`), a **debounced name/email search**, the **assessee's
  org-neighbour suggestions** (manager, peers, direct reports — `Assessments::RequestCandidates`),
  a **multi-select** chip list, **one shared reason**, and an optional due date.
- **Search + suggestions** are server-rendered: the search input (debounced ~250ms by
  [request_evidence_controller.js](../../../app/javascript/controllers/request_evidence_controller.js)
  — now a thin subclass of the shared
  [person_picker_controller.js](../../../app/javascript/controllers/person_picker_controller.js),
  the reusable typeahead+chips control this picker was extracted into; the
  calibration participant picker reuses it via
  [Views::Shared::PersonPicker](../../../app/views/shared/person_picker.rb))
  repoints the `#request-candidates` frame
  ([RequestCandidatesFrame](../../../app/views/evidence/request_candidates_frame.rb));
  selection is client-side (chips + `requestee_ids[]` hidden inputs). People with a
  **pending request on the cell are greyed "Asked"** and can't be re-selected.
  The **assessee themselves is a valid recipient** (surfaced as the first
  suggestion, relation `assessee`) — a manager can nudge their report for more
  evidence; only the **requester** (you) is excluded (asking yourself is
  meaningless). The aggregate + operation enforce the same "not yourself" rule.
- **Two render endpoints** (`EvidenceRequestsController#modal` / `#candidates`,
  assignment-scoped, `EvidenceRequestPolicy#request?`-authorized) feed the lazy modal
  frame and the typeahead frame.
- **Multi-send** — `POST /evidence_requests` loops the single-recipient
  `Operations::Assessments::RequestEvidence` once per `requestee_ids[]` entry (shared
  message + due), flashing a per-batch summary ("Sent to N people · Skipped M"). MCP
  parity is preserved — the op is unchanged; multi-send is a web convenience.
- **Visibility is disclosed to the requestee** before they write a word: the open
  incoming hub card and the respond modal both state the response will be visible
  to the assessee, their managers, and workspace admins (the `EvidencePolicy` view
  rules). Skipped when the requestee IS the assessee. Keep the copy in the two
  surfaces (`HubView#response_visibility_note` / `ModalForm#visibility_note`) in
  step with the policy if view rules ever change.

**Two modal overlays, one `modal` controller.** The assessment screen now hosts both
the evidence modal and the request modal under the wrapper's single `modal`
controller, so **every** evidence/request trigger names its overlay via
`data-modal-target-id` (`evidence-modal-overlay` / `evidence-request-modal-overlay`) —
framework-explorer Hard-Won Lesson 19.

### Reminders and nudges on open requests

An unanswered request doesn't rely on the requestee's memory:

- **Automatic reminders** — the hourly `EvidenceRequestReminderSweepJob` emits
  `EvidenceRequestReminderSent` (kinds `no_response` after 7 quiet days /
  `due_soon` 2 days before the optional due date, whichever comes first; each
  automatic kind at most once, aggregate-guarded). Timing policy — incl. the
  24h floor, 3-day gap, and 30-day rollout cap — lives on
  [`EvidenceRequest`](../../../app/read_models/evidence_request.rb); events carry
  `acting_via: "system"` provenance.
- **Manual nudges** — the requester (or a tenant admin) can chase an open
  request via `Operations::Assessments::NudgeEvidenceRequest`
  (`POST /evidence_requests/:id/nudge` on the web,
  `assessments_nudge_evidence_request` over MCP), repeatable once
  `EvidenceRequest::NUDGE_GAP` (2 days) has passed since the last reminder of
  any kind. Automatic reminders and manual nudges share one clock — a nudge
  defers the sweep and vice versa.
- **Delivery** rides the notification chain: `evidence_request_reminder`
  Noticed type (in-app + Slack default, email deferred) with kind-aware copy;
  the manual copy names the nudger. The async handler drops the nudge if the
  request resolved before the job ran.
- **History** — every reminder is appended to the projected
  `reminder_history` (kind, at, by_id) and stamps `last_reminded_at`, both
  replay-safe. The hub renders the history on every open card and sorts open
  lists stalest-first (`least_recently_touched`).

**Resolution notifications carry the response.** The requester's "answered" /
"declined" notification (in-app + Slack) quotes the response itself — the
evidence content, or the decline reason — excerpted at
`ApplicationNotifier::EXCERPT_LIMIT` (280 chars, shared `quoted_excerpt`
helper) so the Slack DM reads the feedback without a round trip to the hub;
the deep link still lands on the hub card for the full text.

### Assessment-cycle feedback reporting

The cycle's **Feedback & evidence** report counts feedback provision separately
from request workflow:

- `feedback_provided` is every unique active `EvidenceItem` attributed to the
  cycle, including proactive feedback. Multiple `EvidenceLink` rows never
  multiply the count.
- `provided_by_request` is the subset recorded in response to a cycle request;
  proactive feedback is the remainder, exposed by the compatibility field
  `provided_unsolicited = feedback_provided - provided_by_request`.
- Withdrawn items are excluded from active provision and reported separately.
- A relink, migration, or valence change never changes the item's original
  cycle. Prior-cycle evidence reused in this cycle is not newly provided.
- If existing evidence fulfils a new request, the request is fulfilled but the
  item is not counted as new feedback.
- Active feedback is also grouped by immutable provider-to-recipient direction:
  manager → report, peer → peer, or report → manager. Self feedback is separate
  and requested versus proactive remains an orthogonal split.
- Active feedback is also split by origin: `external_reference.system`, with
  none meaning GrowthOS. The report shows "Of which via Chip: N" under the
  provided tile when any item came from another system, and the MCP payload
  carries `by_origin`. Origin does not change what "requested" means: that is
  still a GrowthOS evidence request.

`EvidenceRequested` and `EvidenceRecorded` carry nullable `cycle_id`. Direct
feedback and requests use the PersonDevelopment aggregate's current cycle; a
response explicitly inherits its request's cycle so a late response remains
with the original cycle after close. The projections copy this value without a
`CODE_VERSION` bump. Historical null rows are inferred at report time only when
one enrollment window matches; ambiguous records stay unattributed.

New `EvidenceRecorded` events also carry nullable `feedback_direction`, captured
from the provider and recipient's relationship at write time. Historical
`source: manager` and `source: self` rows retain exact manager → report and self
classification. Historical `source: peer` rows cannot be split reliably, so the
report labels them `Peer → peer or report → manager (historical)` and omits that
row once its count reaches zero. Replays leave the new column null for old
events, so this additive field also needs no projection `CODE_VERSION` bump.

The report is aggregate-only: no contributor identity, content, evidence title,
or individual request row. Managers see their `Person#all_reports` subtree;
admins/HR see the whole cycle and can switch to My org. Web and MCP share
`Operations::Reporting::EvidenceCoverage`.

Either surface can narrow the report to **one calendar month** of the cycle
(`month: "YYYY-MM"` over MCP; a Month select + Apply on the web — a plain GET
form, deliberately not submit-on-change). The month counts feedback by
`recorded_at` and requests by `requested_at`, inside the cycle attribution
above; request statuses stay current, so the two card families use different
windows (see [reporting.md §4.9](../../architecture/reporting.md)). Boundaries are
UTC (`Time.zone`) until tenants carry a zone. `Reporting::CycleMonth` owns the
key format, the label, and the months list that both the select and the MCP
payload's `available_months` render.

**Hub layout** ([hub_view.rb](../../../app/views/evidence/hub_view.rb)): the
"Give feedback" entry in the header → "Feedback to place" (see *Proactive
feedback*) → "May fit elsewhere too" (see *Suggested placement and valence*) → "Open
requests" (subsections *Asked of you* / *Your requests*, stalest first, with
history + respond/decline or nudge/cancel actions) → "Completed requests"
(subsections *Asked of you* / *Your requests* / *Feedback / Evidence you've
provided* — the viewer's authored evidence, edit/withdraw). Every evidence
item on the hub (authored cards + embedded responses) carries a **"View in
assessment"** deep link to its **first active linkage**
(`?capability=` + `?level_ordinal=` — focuses and scrolls the card) so the
feedback can be read in situ; the controller renders it only when
`AssessmentPolicy#show?` admits the viewer, so a peer who provided feedback on
a colleague's assessment gets no dead link.

**Decline stays out of the way of the reply.** On an incoming card, "Decline
request" is a secondary button beside the primary "Provide feedback / evidence"
button, and it opens its own modal with a labelled, multi-line reason field and
a note that the requester will see it. An always-open reason box under the
reply button read as the reply box: a requestee wrote their feedback into it
([#476](https://github.com/mr-yum/growth-os/issues/476)). The reply itself is
written only in the evidence modal.

## Comment notifications

Every posted assessment comment — cell thread or evidence-linkage thread —
notifies the conversation's other parties via
[`PersonDevelopment::AsyncHandlers::CommentNotifier`](../../../app/contexts/person_development/async_handlers/comment_notifier.rb)
(async RES handler on `CommentPosted`; NOT a projection — replaying would
re-send). Three rules, deduped, the author always excluded, one notification
per recipient per comment (a recipient matching several rules gets the most
specific — reply beats the generic kinds):

| Rule | Recipient | `NotificationType` |
|---|---|---|
| Reply | The parent comment's author | `comment_reply` |
| Comment by anyone ≠ assessee | The assessee | `assessment_commented` |
| Comment by the assessee | The **recorded reporting manager** (live `Person.manager_id` fallback) **+ active rating delegates** | `team_assessment_commented` |

Edits and deletes stay silent (the thread shows them). Skip-level ancestors
and tenant admins can read threads but get no pings — observers, not parties.
Recipients are by construction inside the comment-visibility set; the peer
evidence author is excluded from linkage threads upstream, so no leak is
possible. Bodies use `quoted_excerpt` with a context line ("«evidence
author»'s feedback · «Capability» · L«n»"); the deep link carries the
existing `?capability=` + `?level_ordinal=` focus params, and one URL serves
both parties (the show route renders per-viewer context).

**Delivery is in-app-first everywhere**: external channels (Slack) fire only
if the recipient hasn't read the in-app copy within
`ApplicationNotifier::ESCALATION_DELAY` (1 minute) — the smart-escalation
rules in [`ApplicationNotifier`](../../../app/notifiers/application_notifier.rb),
shared by every notification type. The **first Slack DM a user ever
receives** carries a one-time footer disclosing this model and linking
`/settings/notifications` (a persisted fact —
`User#external_notifications_disclosed_at`, marked only after a successful
post — see [`SlackDeliveryMethod`](../../../app/notifiers/slack_delivery_method.rb));
the notification bell's dropdown links the same page persistently via a gear
icon.

## Also in a peer system

When a peer feedback system (Chip) acknowledges that it imported one of our items through the [feedback exchange](../feedback-exchange.md), the evidence card wears an **Also in Chip** chip beside the type label, linking to the peer's own copy in a new tab. It is read from `feedback_exchange_acks` through the transient `EvidenceItem#exchange_acks`, filled by `EvidenceItem.load_exchange_acks` in the matrix builder and in the single-cell evidence controller (one query for the page). An address that is not http(s), or an ack without one, renders as a plain chip with no link. Nothing about the item changes: the ack only says where else it lives.
