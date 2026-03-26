# Architecture & Design — Index

> This file is an index. Read the linked files on demand rather than all at once.

**Stack:** Rails 8 · RailsEventStore ~> 2.16 · PostgreSQL · Solid Queue · Devise · acts_as_tenant

---

## Architecture Files

| File | Read when |
|------|-----------|
| [adrs.md](architecture/adrs.md) | Making architectural decisions; understanding *why* things are built a certain way; evaluating trade-offs for new approaches |
| [domain-models.md](architecture/domain-models.md) | Working on Tenant, User, TenantUser, or Person; adding auth or multi-tenancy logic; writing migrations for these tables |
| [framework-aggregate.md](architecture/framework-aggregate.md) | Working on framework features — roles, capabilities, expectations, illustrations, suggested edits, versioning, or collaborators |
| [person-development-aggregate.md](architecture/person-development-aggregate.md) | Working on assessments, evidence, growth plans, alignment conversations, check-ins, or framework migration |
| [scoring-model.md](architecture/scoring-model.md) | Working on assessment scoring, the capability matrix display, performance verdicts, promotion readiness, the scoring panel UI, or framework scoring settings |
| [reporting.md](architecture/reporting.md) | Working on reporting — gap analysis, trend analysis, promotion readiness dashboards, growth plan freshness, evidence density |
| [integrations.md](architecture/integrations.md) | Working on HRIS sync, notification adapters, or SSO/SAML |
| [event-store.md](architecture/event-store.md) | Configuring event subscriptions, adding new projections, working with snapshots, or adding async handlers |

---

## Nine Key Capabilities (Product)

| # | Capability |
|---|-----------|
| 1 | Role-based career paths with capability categories shared across roles or specific to one |
| 2 | Behavioural expectations per capability, per level, per role |
| 3 | Regular self-assessment and manager alignment (async, live, or record-only) with historical trend analysis |
| 4 | Evidence/feedback collection from self, managers, and peers — re-linkable between capabilities |
| 5 | Framework evolution over time without losing existing data |
| 6 | Differential capability weighting per role |
| 7 | Deficit threshold requirements — zero-tolerance (deficit_threshold=0) through fully-flexible (nil inherits framework default) |
| 8 | Growth plans with focus areas, regular check-ins, and freshness reporting |
| 9 | Aggregate gap reporting across roles |

---

## Capability-to-Implementation Mapping

| # | Capability | Implementation |
|---|-----------|---------------|
| 1 | Role-based paths, shared/specific capabilities | `CapabilityRoleBinding` scopes capabilities to roles. `RoleFamily` groups related roles for mobility. |
| 2 | Behavioural expectations per cap/level/role | `BehaviouralExpectation` (canonical, rated) + `RoleIllustration` (clarifying, not rated). |
| 3 | Self-assessment + alignment with history | Person Development stream: `SelfRated` → `ManagerRated` → `CapabilityAligned` → `FullAlignmentCompleted`. Three alignment modes. Trend via `capability_stable_id`. |
| 4 | Evidence from self/manager/peers, re-linkable | `EvidenceRecorded` / `EvidenceRelinked` events. Semi-freeform types + `ExternalReference`. |
| 5 | Framework evolution | Event-sourced Framework with versioning. `stable_id` continuity. `requires_reassessment` flag. Nothing silently dropped. |
| 6 | Weighted capabilities | `CapabilityRoleBinding.weight` — per-role weighting. Contributes to scoring as `(effective_frequency − expected) × weight`. |
| 7 | Deficit threshold requirements | `deficit_threshold` (resolved per capability: binding → category → framework, default 1.0). Dual purpose at category level. `overperformance_cap` (resolved same hierarchy, default 1). |
| 8 | Growth plans + check-ins + freshness | Growth events in Person Development stream. `GrowthPlanState` projection. Freshness = `last_check_in_at` delta. |
| 9 | Aggregate gap reporting | `Reporting::GapAnalysis` async projection. Aggregates `effective_frequency` vs expected across people per role. |

---

## Module Boundaries

```
┌──────────────────────────────────────────────────────────────┐
│                    SaaS Control Plane (open-source)           │
│  Tenant provisioning, billing, SSO routing, usage metrics     │
└────────────────────────┬─────────────────────────────────────┘
                         │
┌────────────────────────▼─────────────────────────────────────┐
│                   Open Source Core (Rails 8)                   │
│                                                               │
│  ┌──────────────┐  ┌──────────────────────┐                  │
│  │  Frameworks   │  │  PersonDevelopment    │                 │
│  │  (ES/RES)     │  │  (ES/RES)            │                 │
│  └──────────────┘  └──────────────────────┘                  │
│                                                               │
│  ┌──────────┐  ┌──────────┐  ┌───────────┐  ┌────────────┐ │
│  │ Person   │  │ Reporting │  │ Template  │  │ User/Auth  │ │
│  │ (AR)     │  │ (read)    │  │ Library   │  │ (Devise)   │ │
│  └──────────┘  └──────────┘  └───────────┘  └────────────┘ │
│                                                               │
│  ┌───────────────────────────────────────────────────────┐   │
│  │  Integration Layer                                     │   │
│  │  HRIS adapters · Notification outbox · Auth providers  │   │
│  └───────────────────────────────────────────────────────┘   │
│                                                               │
│  ┌───────────────────────────────────────────────────────┐   │
│  │  RailsEventStore (ActiveRecord-backed, Postgres)       │   │
│  │  + Solid Queue (async handlers)                        │   │
│  └───────────────────────────────────────────────────────┘   │
└───────────────────────────────────────────────────────────────┘
```
