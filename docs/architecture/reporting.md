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
  "completion" event — `self_completed_at` / `manager_completed_at` are unused.
- **At-risk**: not yet aligned AND (past the cycle's `planned_end_at` OR ≥14 days
  with no enrolment/lifecycle/rating activity).
- **Grouping**: by manager subtree / role / level (enrollment snapshot columns).
- **Modes**: `:summary` (funnel + counts + most-lagging subtree, for the Home
  card) and `:full` (adds grouped breakdowns + per-participant rows, for the
  drill-down view).

**Privacy invariant**: exposes only lifecycle status and completion counts —
**never rating values or individual scores**. Skip-level viewers see funnel
position per person, nothing finer.

**Surfaces** (one implementation, three entry points):
- Home cohort card — `Home::CycleProgressCard` (summary mode, one per open cycle).
- Drill-down view — `GET /assessment_cycles/:id/cohort`
  (`AssessmentCycles::CohortsController`, full mode).
- MCP — `Operations::Reporting::CycleCohort` (`reporting_cycle_cohort`, summary by
  default).

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
- **Grouping**: assessed person by live manager, enrollment-snapshot role, or
  enrollment-snapshot level. Contributor identities and feedback content never
  enter the result.

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
exist. This additive nullable field does not change how identical events replay,
so `EvidenceCollection::CODE_VERSION` remains 3 and no rebuild is required.

**Surfaces**:

- Web — `GET /assessment_cycles/:id/evidence`, with whole-cycle / My-org scope
  and manager / role / level tabs.
- MCP — `Operations::Reporting::EvidenceCoverage`
  (`reporting_evidence_coverage`, summary by default, `mode: "full"` for groups).

**Authorization**: `AssessmentCyclePolicy#evidence_report?`, the same audience
and subtree rules as cohort and attainment reporting.


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
