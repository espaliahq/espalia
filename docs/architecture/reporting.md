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
