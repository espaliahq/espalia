# Reporting Read Models

> Read this when: working on reporting features, gap analysis, trend analysis, promotion readiness dashboards, growth plan freshness, or evidence density views.

Async projections (via Solid Queue), updated on relevant events.

---

## 4.1 Individual Capability Heatmap

Capability × Expected Level × Self-rated × Aligned. Colour-coded gap visualisation.

---

## 4.2 Trend Analysis

Time-series of aligned ratings per capability using `capability_stable_id` across versions.

---

## 4.3 Aggregate Gap Report — Capability Attainment (shipped)

Per role and role family: the share of an assessment cycle's participants at or
above their assessed level on each bound capability, plus a category roll-up.
**Compute-on-read** (no projection, no new tables): `Reporting::CapabilityAttainment`
([app/queries/reporting/capability_attainment.rb](../../app/queries/reporting/capability_attainment.rb))
builds one `PersonDevelopment::Scoring` per participant at their **enrollment-snapshot**
role/level (ADR-19) from a single bulk `AssessmentLevelRating` query.

- **Buckets** per person × capability, from `Scoring#agreed_level_for` (highest
  level rated consistent): `above` (> assessed level), `at` (=), `below`
  (otherwise — including not-yet-assessed, so every cell carries
  `n_assessed / n_in_group` coverage and the UI renders them together).
- **Perspective-parameterised**: effective (default, aligned → manager → self),
  self-only, manager-only, aligned-only — the report labels which is active.
- **Family roll-ups** use per-capability denominators (only people whose role
  binds the capability). **Category roll-up** is the share of people passing
  the existing category gate (`Scoring#category_results`) — deliberately not
  arithmetically composed from the capability cells.
- Keyed on `capability_stable_id` → survives framework version migrations.

**Privacy — small-cohort suppression.** The invariant: never show an
aggregate derived from data the viewer cannot open at the individual level.
When suppression applies, any cell under `MIN_COHORT` (4) people keeps its
coverage counts but hides buckets/percentages; family cells add a differencing
guard (suppressed when the remainder behind visible role cells is a
reconstructable 1..3 people). **Currently every attainment viewer is
unsuppressed** (`AssessmentCyclePolicy#attainment_unsuppressed?`): since
`AssessmentPolicy#show?` grants the full live manager chain individual view
access, a manager's aggregate scope (`Person#all_reports`, the same live chart
walk) is exactly the set whose assessments they can already open — the
aggregate discloses nothing new. The suppression machinery is retained in the
query for future audiences whose individual-level visibility does not cover
their aggregate scope (e.g. org-wide member transparency, department-scoped HR
viewers) — wire such an audience by returning false from
`attainment_unsuppressed?`. Never exposes individual ratings.

**Surfaces** (one implementation, two entry points):
- Drill-down heatmap — `GET /assessment_cycles/:id/attainment`
  (`AssessmentCycles::AttainmentsController`; categories × capabilities rows,
  role/family columns, perspective + axis + scope switchers). Linked from the
  cycle page and the cohort view.
- MCP — `Operations::Reporting::CapabilityAttainment`
  (`reporting_capability_attainment`).

**Authorization**: `AssessmentCyclePolicy#attainment?` — same bar as `cohort?`
(any manager with a participant in their subtree; admins/HR whole-cycle, with
the same `?scope=mine` toggle).

---

## 4.4 Promotion Readiness

Meeting expectations at the next level: `performance_ratio_at_level(person_level + 1) >= meeting_expectation_threshold` AND no capabilities with `deficit > deficit_threshold` (blocked) at `person_level + 1`.

---

## 4.5 Growth Plan Freshness Dashboard

Per manager: reports with last check-in, plan status. >30 days amber, >60 red.

---

## 4.6 Evidence Density

Per person per capability: evidence count by source. Highlights sparse areas.

---

## 4.7 Career Mobility View

Current role vs target role: capability overlap, gaps, illustration differences.

---

## 4.8 Assessment-Cycle Cohort Roll-up

Aggregate view of how an assessment cycle is progressing across an org subtree
— for managers (their subtree) and admins/HR (the whole cycle). **Compute-on-read**
(no projection, no new tables): `Reporting::CycleCohort`
([app/queries/reporting/cycle_cohort.rb](../../app/queries/reporting/cycle_cohort.rb))
aggregates the existing read models at query time.

- **Funnel** (the headline): Self → Manager → Aligned as head counts. Self/manager
  completion is **derived from coverage** — a participant is "self-done" when every
  capability bound to their **assessed role** (enrollment snapshot, ADR-19) has a
  self rating at their **assessed level**. Aligned is the one explicit milestone
  (`AssessmentCycleProgress.status == "aligned"`). There is no explicit self/manager
  "completion" event. `CurrentAssessment` stamps `self_completed_at` /
  `manager_completed_at` on every rating event from `Assessments::LevelCoverage`
  ([assessments/lifecycle.md](../guidelines/assessments/lifecycle.md)), which is
  not quite the funnel's rule: it counts only human ratings (the funnel counts
  anything not seeded), reads the live assignment's role (the funnel reads the
  enrollment snapshot), and refreshes only when someone rates. So a stamp can
  disagree with `self_done` / `manager_done` after a role change or a framework
  publish, until the next rating.
- **At-risk**: not yet aligned AND (past the cycle's `planned_end_at` OR ≥14 days
  with no enrolment/lifecycle/rating activity).
- **Grouping**: by manager subtree / role / level (enrollment snapshot columns).
- **Modes**: `:summary` (funnel + counts + most-lagging subtree, for the Home
  card) and `:full` (adds grouped breakdowns + per-participant rows, for the
  drill-down view).
- **When**: each participant carries a `Lifecycle` (enrolled, started, self and
  manager complete, alignment started and completed, with actors) and, in full
  mode, one `RoleAlignment` per role aligned this cycle (home and lens, with
  `reopened_at`; loaded only when the caller passes `include_role_alignments:`,
  as the MCP operation does). The result carries `median_days_to_align`. Every
  stamp is the **latest** occurrence: a re-open clears `aligned_at` until the
  next completion. First completions and re-open history live only in the event
  stream.

**Access and privacy**: the manager chain and tenant admins may see everything
about a person, timestamps included, so skip-level viewers get the same rows as
direct managers. The report still returns **no rating values or individual
scores**: it reports progress, and scores have their own surfaces.

**Surfaces** (one implementation, three entry points):
- Home cohort card — `Home::CycleProgressCard` (summary mode, one per open cycle).
- Drill-down view — `GET /assessment_cycles/:id/cohort`
  (`AssessmentCycles::CohortsController`, full mode).
- MCP — `Operations::Reporting::CycleCohort` (`reporting_cycle_cohort`, summary by
  default). Full mode returns the lifecycle timestamps; `aligned_from` /
  `aligned_to` (UTC dates, full mode only) keep participants with an alignment
  against any role completed in the window. They narrow the list, not the
  funnel.

**Authorization**: `AssessmentCyclePolicy#cohort?` (any manager with a participant
in their `Person#all_reports` subtree) / `#cohort_full_access?` (admins/HR see the
whole cycle). A full-access viewer who is also a manager can narrow to their own
subtree via `?scope=mine` (web) / `scope: "mine"` (MCP) — the drill-down renders a
"My org / Whole cycle" toggle. Impersonation is honoured correctly: `pundit_user`
acts as the impersonated target (`Impersonatable#effective_user`), so an admin
viewing-as a member sees only what that member would — no full-cycle leak.

**Follow-ons** (deferred): denormalize completion counts onto
`AssessmentCycleProgress` (owned by `CurrentAssessment`) if compute-on-read proves
slow — `CODE_VERSION` bump + rebuild; participant-list pagination; department/team
grouping once HRIS provides it; score-distribution drill-down with careful auth.
## 4.9 Assessment-Cycle Feedback & Evidence Coverage

Aggregate workflow report for feedback requested and provided during an
assessment cycle. **Compute-on-read** (no reporting projection):
`Reporting::EvidenceCoverage` joins cycle enrollments to the existing
`EvidenceRequest` and `EvidenceItem` read models and deduplicates by evidence
item ID, never by capability link.

- **Feedback provided**: unique active evidence items attributed to the cycle.
  `provided_by_request` is the subset recorded after and attached to a fulfilled
  cycle request; proactive feedback is the remainder (serialized under the
  compatibility key `provided_unsolicited`). Withdrawn items are excluded from
  provided totals and reported separately.
- **Requests**: sent, fulfilled, pending, declined, and cancelled. Fulfilment
  rate is fulfilled / non-cancelled; request counts and evidence counts remain
  separate units.
- **Participant coverage**: active cycle participants with at least one active
  cycle feedback item / active participants.
- **Feedback directionality**: active attributed items split into manager →
  report, peer → peer, and report → manager. Self-provided feedback is separate;
  historical peer-source items without a persisted direction use a visible
  peer-or-upward combined bucket.
- **Origin**: `by_origin` splits `feedback_provided` by
  `external_reference.system` (none, or a plain link target such as a GitHub
  PR or a Slack message, = `growthos`: that feedback was given here), so the values sum to the
  provided total. `growthos` is always present, other systems appear when they
  have items, largest first. The web report shows "Of which via Chip: N" under
  the provided tile, only when an origin other than GrowthOS is non-zero; MCP
  returns the map keyed by system slug (`Reporting::OriginLabels` turns a slug
  into the display name). Imported items stay in every other figure: direction,
  coverage and the month filter read them like any item. "By request" still means
  a GrowthOS evidence request, so feedback a peer system collected in answer to
  its own request counts as proactive here; the export's *Origin request* column
  says it was asked for.
- **Counted once.** A figure combined across systems counts each item in the
  system it was given in. An item that crossed from Chip appears in both
  systems' totals, so a People & Culture total that adds the two double-counts it.
  Take the GrowthOS figure as `by_origin.growthos`, and the other system's as
  that system's own native count.
- **Grouping**: assessed person by live manager, enrollment-snapshot role, or
  enrollment-snapshot level. Contributor identities and feedback content never
  enter the result.
- **Monthly period**: an optional `month` (`YYYY-MM`, one of the months the
  cycle's activity can fall in — `Reporting::CycleMonth.available_for`, which
  runs from the opening month through the current month for an open cycle, and
  through the close *or the latest cycle-attributed activity* for a closed one,
  so a late response recorded after close stays selectable — including a legacy
  null-cycle response, found through its in-span request) narrows the counts
  to feedback **recorded** and requests **sent** in that calendar month. Cycle
  attribution runs first, so a month is always a slice of the cycle.
  Participants stay the cycle's participants (coverage is "participants with
  feedback that month"). Two deliberate consequences, both stated in the
  report's note: the feedback and request cards use **different windows**
  (feedback answering an earlier month's request is "by request" in the month
  it was recorded, while the request counts — with its *current* status — in
  the month it was sent, so monthly by-request feedback and fulfilled requests
  need not agree), and withdrawn / cancelled items follow their original
  timestamp, not the withdrawal. Month boundaries are `Time.zone` — **UTC**,
  as neither the app nor tenants configure a zone — so the payload's
  `starts_at` / `ends_at` are the authoritative window; a per-tenant zone is a
  follow-up. The payload carries the resolved `period` (nil for the whole
  cycle) and `available_months` so a client never has to guess the valid keys.

**Immutable attribution.** New `EvidenceRequested` and `EvidenceRecorded`
events carry nullable `cycle_id`; their projections copy it to
`evidence_requests` / `evidence_items`. Direct feedback uses the aggregate's
current cycle. A response inherits the request cycle even after close. Adding,
removing, migrating, or revaluing `EvidenceLink` rows never changes an item's
cycle, so prior-cycle evidence relinked now is not new provision. If old evidence
fulfils a new request, the request is fulfilled but no new feedback is counted.

Historical rows remain null — there is no projection version bump or backfill.
The query infers a legacy timestamp only when exactly one enrollment window in
the framework contains it. A legacy post-close response inherits an
unambiguous request window; ambiguous history stays unattributed.

**Immutable direction.** New `EvidenceRecorded` events carry nullable
`feedback_direction`, classified from provider to recipient when the feedback
is recorded. Manager-source feedback (including manager-capacity delegates) is
manager → report. Peer-source feedback from someone in the recipient's report
tree is report → manager; other peer-source feedback is peer → peer. The
projection persists that fact, so later org-chart changes never rewrite it.

Events published before direction capture replay to `NULL`: historical
`source: manager` maps to manager → report, historical `source: self` remains
self-provided, and historical `source: peer` maps to
`legacy_peer_or_upward`. That combined bucket is emitted only while such items
exist.

An item whose author is its recipient is self-provided, whatever its event
says (`EvidenceItem#self_authored?`). Until October 2026 an assessee's answer
to a request about their own assessment was recorded as peer → peer, and the
event cannot be corrected. This additive nullable field does not change how identical events replay,
so `EvidenceCollection::CODE_VERSION` remains 3 and no rebuild is required.

**Surfaces**:

- Web — `GET /assessment_cycles/:id/evidence`, with whole-cycle / My-org scope,
  manager / role / level tabs, and a Month select + Apply (`?month=YYYY-MM`; an
  unknown month falls back to the whole cycle like the other filter params, with
  a flash saying so since the shared URL still names a month).
- MCP — `Operations::Reporting::EvidenceCoverage`
  (`reporting_evidence_coverage`, summary by default, `mode: "full"` for groups,
  `month: "YYYY-MM"` for one month — a malformed or out-of-cycle month is a
  `ParameterError`, -32602).

**Authorization**: `AssessmentCyclePolicy#evidence_report?`, the same audience
and subtree rules as cohort and attainment reporting.

## 4.10 Feedback Export (CSV)

The row-level companion to 4.9, for People & Culture's monthly reporting: every
piece of feedback a cycle holds, one row each, with names and content. Where
4.9 counts, this lists — so it has a narrower audience and its own privacy bar.

- **Grain**: one row per `EvidenceItem`. Its active `EvidenceLink`s collapse
  into one *Applies to* cell ("Strategic Thinking · E2 · Demonstrates; …"), so a
  pivot over the file still counts pieces of feedback, not links.
- **Attribution parity**: `Reporting::FeedbackExport` reads the same
  participants (active cycle enrollments) and the same rules as 4.9 — both go
  through `Reporting::EvidenceAttribution` (explicit `cycle_id`, else the
  answered request's cycle, else exactly one enrollment window). With withdrawn
  items left out, the row count equals 4.9's `feedback_provided` for the same
  cycle and month, and the *Requested* rows equal its `provided_by_request`.
  `include_withdrawn` adds the withdrawn items (4.9's `feedback_withdrawn`). The
  `month` filter is 4.9's: feedback **recorded** in that calendar month (UTC).
- **Columns**, in order (`Operations::Reporting::FeedbackExport::COLUMNS` is the
  one list — the CSV header, the JSON `columns` and each row's keys):

  | Column | Source |
  |---|---|
  | Cycle | `AssessmentCycle#name` |
  | Recorded at | `recorded_at`, ISO 8601 UTC |
  | Recipient / Recipient email | `person_id` → Person |
  | Recipient role / Recipient level | the cycle enrollment snapshot (`Role#name`, `Level#title`), else the live framework assignment |
  | Recipient manager | the recipient's live manager |
  | Provider / Provider email / Provider role | `author_id` → Person, role as for the recipient |
  | Direction | *Self* when the provider is the recipient, else `feedback_direction`, else the legacy `source` fallback 4.9 uses, in 4.9's labels |
  | Requested or proactive | *Requested* when the item answered a request of this cycle (4.9's rule — evidence older than the request was reused, so it stays *Proactive*) |
  | Requested by / Requested at | that request |
  | Type | `evidence_type` humanised, or `custom_type_label` for *other* |
  | Title / Feedback | `title` / `content` |
  | Applies to | active links (or, for a withdrawn item a migration left with none, the links it had): capability name (from the cycle's framework) · the recipient role's level code (`L<n>` when the role has none) · valence label |
  | Status / Withdrawn at | `link_status`, `withdrawn_at` |
  | Reference link | `external_reference.safe_url` (http/https only) |
  | Origin | the system the item was given in, from `external_reference.system` through `Reporting::OriginLabels` ("GrowthOS" when there is none or it is a plain link target such as GitHub or a Slack message, since that feedback was given here; "Chip" or another peer's name titleised otherwise) |
  | Origin request | `external_reference.metadata.request_context`: what the item answered in its source system. Blank when there is none. *Requested or proactive* is unchanged and means a GrowthOS request only, so a peer item that answered a request in Chip reads *Proactive* there and carries the request here |

- **The file**: `text/csv`, UTF-8 with a byte-order mark (so Excel reads "→"
  and accented names correctly), named
  `growthos-feedback-export-<cycle-slug>-<YYYY-MM|all>-<UTC timestamp>.csv`. A
  cell that starts like a formula (`=`, `+`, `-`, `@`, tab, CR) is prefixed with
  an apostrophe — the cells hold text people typed, and a spreadsheet would
  otherwise run it (`Reporting::FeedbackExportCsv`).
- **Privacy bar**: `TenantPolicy#export_feedback?` — tenant admins (or global
  admins) **with a linked Person**, so every export is attributable. Managers
  are refused even for their own reports: 4.9 shows them counts, never content.
  The export is refused while an admin is viewing as another user, although it
  writes nothing — the Operation checks `AuditMetadata`'s
  `impersonation_active`, so the web and MCP refuse alike. Each export logs one
  info line: `[feedback_export] actor_person_id=… cycle_id=… month=… include_withdrawn=… rows=…`.

**Surfaces**:

- Web — the *Feedback export* section of tenant admin
  (`GET /tenant/feedback_exports/new`: choose a cycle, then a month and whether
  to include withdrawn feedback) downloads `GET /tenant/feedback_exports.csv`.
  The cycle's feedback & evidence report (4.9) shows tenant admins a *Download
  CSV* button carrying the cycle and the month on screen (never the My-org
  scope — the export covers every participant, and under My org the label
  says "all participants"). An unknown `cycle_id` offers no download rather than
  falling back to another cycle. Both are full navigations (`data-turbo="false"`): Turbo cannot hand
  a file to the browser. The file is sent `Cache-Control: no-store`.
- MCP — `Operations::Reporting::FeedbackExport` (`reporting_feedback_export`,
  `:read`, approval `:none`) returns `{ cycle:, period:, include_withdrawn:,
  columns:, rows: }` — the same rows as JSON.

## 4.11 Cycles to Report On (MCP)

Every cycle report above takes a `cycle_id`. `reporting_cycles_list`
(`Operations::Reporting::CyclesList`, `:read`, approval `:none`) is where an MCP
client finds one, closed cycles included: id, name, type, status, framework,
version range, opened / planned end / closed dates and participant count,
newest first, filterable by `status` and `framework_id`.

**Access** is the cohort report's, so the list never offers a cycle whose
report would be refused: `AssessmentCyclePolicy#report_index?` admits any
member, and `AssessmentCyclePolicy::Scope` keeps every cycle for admins/HR and,
for anyone else, the cycles with a non-withdrawn participant in their
`Person#all_reports` subtree — the same rule as `cohort?`, pinned by a parity
test. `participant_count` follows the cohort report too: whole cycle for
admins, the subtree otherwise. `index?` (the admin cycle pages) stays
admin-only.

There is no web surface: the web reaches cycles from Home and the admin pages.


## Home dashboard

`HomeController#show` renders a composable, role-aware card grid (replacing the
old root redirect). The card framework — `Home::Card` + `Home::Registry`
([app/dashboard/home/](../../app/dashboard/home/)) — lets each card declare its
audience and priority and emit 0..N instances; each instance lazy-loads its
content in its own Turbo Frame via `HomeController#card`. The cohort card above
is the first reporting-driven card; assessment-progress and awaiting-you cards
ship alongside it.

**Recent activity card** (`Home::RecentActivityCard`) surfaces a short feed of
recent assessment activity — for an IC their own, for a manager their direct
reports'. Built from `Assessments::RecentActivityQuery`, which assembles ratings
/ evidence / comments / alignment milestones cheaply from read models with
bounded `ORDER ... LIMIT` queries — **never** the per-assignment event replay of
`Assessments::ActivityFeedQuery` (O(people × stream)). Rendered as actor-led
sentences with the capability linked to the assessment cell; exposes activity
metadata only, never rating values. Shared with MCP via
`Operations::Assessments::RecentActivity` (`assessments_recent_activity`).
