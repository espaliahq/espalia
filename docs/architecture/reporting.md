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

## 4.3 Aggregate Gap Report

Per role: count below/at/above expected level per capability. Weighted by binding weights.

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
whole cycle).

**Follow-ons** (deferred): denormalize completion counts onto
`AssessmentCycleProgress` (owned by `CurrentAssessment`) if compute-on-read proves
slow — `CODE_VERSION` bump + rebuild; participant-list pagination; department/team
grouping once HRIS provides it; score-distribution drill-down with careful auth.

## Home dashboard

`HomeController#show` renders a composable, role-aware card grid (replacing the
old root redirect). The card framework — `Home::Card` + `Home::Registry`
([app/dashboard/home/](../../app/dashboard/home/)) — lets each card declare its
audience and priority and emit 0..N instances; each instance lazy-loads its
content in its own Turbo Frame via `HomeController#card`. The cohort card above
is the first reporting-driven card; assessment-progress and awaiting-you cards
ship alongside it.
