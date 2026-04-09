# Career Growth Framework — Glossary & Key Terminology

> Precise definitions of every domain and technical term. Consult when naming is ambiguous.

---

## Domain Concepts

### Framework
The configurable career path blueprint. Event-sourced via RES as a single stream per framework (`tenant-{id}/Framework-{id}`). Versions are points in the stream marked by `FrameworkVersionPublished` events. **Shape-changing events** (see below) accumulate in a draft phase and become visible on publish. **Editorial / shape-preserving events** apply immediately regardless of draft state.

### Shape-changing event
A framework event that alters the `(capability_stable_id, level_ordinal)` rating grid that in-flight assessment cycles depend on. Deferred in the published projection while `draft_in_progress` is true; replayed when `FrameworkVersionPublished` triggers a rebuild. Aggregate-enforced to only fire inside a draft phase via `ensure_draft_in_progress!`. Examples: `CapabilityAdded`, `CapabilityArchived`, `LevelAdded`, `LevelOrdinalChanged`, `CapabilityRoleBindingCreated`/`Removed`, `BehaviouralExpectationSet`.

### Editorial event
A framework event that rewrites or adds content without changing the rating grid. Applies immediately to the published view regardless of draft state. No draft required, no version bump. Examples: `RoleFamilyUpdated`, `CapabilityCategoryAdded`, `BehaviouralExpectationUpdated`, `CapabilityRoleBindingUpdated` (weight), all `RoleIllustration*` events.

### Bootstrap draft
The implicit v1 draft opened by `FrameworkCreated`. The aggregate emits `FrameworkCreated` followed by `DraftVersionStarted(target_version: 1, started_by: "system")` in a single `create` command. The caller populates the framework with shape-changing content and calls `publish_version` to produce v1. See ADR-5.

### Role Family
Grouping of related roles. Example: "Engineering" contains "Software Engineer" and "Engineering Manager". Enables career mobility visibility.

### Role
Job function within a role family. Has `code` (e.g. "E"), `track` (`ic` | `management` | `hybrid`).

### Level
Seniority tier within a role. Has `ordinal` (ordering), `title` (e.g. "Senior Software Engineer"), `code` (e.g. "E3"). Levels are cumulative — each includes everything from preceding levels.

### Capability
Named skill or behavioural dimension people are assessed against. Belongs to a `CapabilityCategory` (organisational grouping). Bound to specific roles via `CapabilityRoleBinding`.

### stable_id
UUID linking the "same" concept across framework versions. When a capability evolves, its `stable_id` persists. This is how trend analysis, evidence continuity, and cross-version queries work.

### CapabilityRoleBinding
Ties a capability to a role. Two critical properties:
- **weight** (decimal): How much this capability counts toward composite scoring for this role.
- **requirement_type** (`must_have` | `flexible`): `must_have` gates performance and promotion. `flexible` allows trade-offs (e.g. front-end vs back-end depth).

This entity IS the capability scoping mechanism. No category-level scope exists. A capability bound to many roles is de facto org-wide; bound to one is role-specific.

### BehaviouralExpectation
The canonical, org-wide definition of what good looks like for a Capability at a Level. **One per Capability × Level. This is what people are rated against.** Example: "Assesses challenges with a critical lens, considers trade-offs, and makes sound decisions with incomplete information."

### RoleIllustration
Clarifying example of how a BehaviouralExpectation manifests in a specific role. **Multiple per BehaviouralExpectation × Role. NOT separately rated.** Helps people interpret the expectation for their role context. Example for Engineers: "Evaluates technical approaches weighing maintenance cost, timeline, and team capability."

### SuggestedEdit
Atomic, inline edit suggestion on a framework entity. Rendered in context (Google Docs suggestion mode). Flows through tiered review. Part of the Framework event stream as `EditSuggested` / `SuggestionApproved` / `SuggestionRejected` events. Applied immediately on approval — continuous delivery.

### FrameworkCollaborator
Permission role on a framework. Eight roles: `owner` (full control + manage collaborators), `editor` (full structural/content but no collaborator management), `role_family_lead` / `role_lead` (scoped to their family/role + exclusively-bound capabilities), `capability_category_lead` / `capability_lead` (scoped to their category/capability), `collaborator` (can see drafts, suggest edits, and comment), `viewer` (published view only, no interaction). A person can hold multiple roles; permissions are the union. See architecture doc section 3.5.6 for full details.

---

## Assessment & Development Concepts

### Person Development Stream
One RES event stream per person per framework (`tenant-{id}/PersonDev-{person_id}-{framework_id}`). The unified development journey: evidence, ratings, alignment conversations, growth plans, check-ins. What was previously three aggregates (Assessment, Evidence, GrowthPlan) is one continuous narrative.

### Assessment Cycle
Time-bounded prompt for self-rating and alignment. Has `cycle_type` (`regular`, `performance_review`, `promotion_review`). Doesn't own assessments — it's a coordination mechanism generating `AssessmentCycleOpened` events across person streams.

### Self-Rating / Manager Rating / Aligned Rating
Three perspectives on a person's level for a capability. Aligned is the "official" record for reporting and trend analysis.

### Alignment
Conversation to agree on capability ratings. Three modes: `async` (comment threads), `live` (real-time), `record_only` (outcome of offline conversation).

### FullAlignmentCompleted
Key event marking when all capabilities have been aligned for a cycle. Natural snapshot point for RES. Replaying to this event gives exact "official" assessment state.

### Evidence
Feedback, observation, or documented behaviour. Has `source` (self/manager/peer), `evidence_type` (predefined enum + `other` with `custom_type_label`), optional `ExternalReference` (system, url, external_id, metadata) for linking to GitHub PRs, Linear issues, Slack threads, etc.

### Evidence Relinking
`EvidenceRelinked` event. Changes which capability/level evidence is associated with. Original link preserved in event history — full audit trail.

### ArchivedCapabilityAcknowledged
When framework versioning archives a capability with existing ratings, the person must `relink` (move context to active capability) or `dismiss`. Assessment can't complete until all resolved.

### requires_reassessment
Flag on `FrameworkMigration` mappings. Signals prior rating may no longer be meaningful. Set automatically for splits and meaningful changes. Can be set manually for any reason. Tracked via `ReassessmentFlagged` / `ReassessmentResolved` events in person streams.

---

## Growth Plan Concepts

### GrowthPlan (projected from events)
Development plan within a person's development stream. Goal + target date + focus areas + check-ins. Lifecycle: `draft` → `agreed` → `in_progress` → `reviewed` → `superseded`.

### goal_type
`close_gaps` | `next_level` | `career_mobility` | `skill_development`

### FocusArea
Development focus loosely tied to a capability (nullable for cross-cutting). Gap identified + success criteria + action plan + action type (70/20/10: on_the_job, coaching, training).

### CheckIn
Monthly touchpoint. `CheckInRecorded` event with focus areas discussed, progress, feedback, next steps. Append-only (amendments via explicit `CheckInAmended` event).

### Freshness
Derived metric: time since last `CheckInRecorded`. >30 days amber, >60 red. Powers the manager dashboard.

---

## Technical Concepts

### Event Store (RES)
RailsEventStore with `ActiveRecord`-backed repository. Tables: `event_store_events`, `event_store_events_in_streams`. Optimistic concurrency via stream version. JSON serialization.

### Stream
Ordered event sequence for an aggregate instance. Named `tenant-{id}/Framework-{id}` or `tenant-{id}/PersonDev-{person_id}-{framework_id}`. Stream name is the tenant isolation boundary in the event store.

### Projection
Read model materialised from events. Synchronous projections update in the same transaction (via RES `Dispatcher`). Async projections via `ActiveJobScheduler` + Solid Queue. Projections are standard ActiveRecord models with `acts_as_tenant :tenant`.

### Snapshot (RES)
Serialised aggregate state at a specific event version. `AggregateRoot::SnapshotRepository` stores snapshots in a `*_snapshots` stream. Speeds up aggregate loading — replay from latest snapshot instead of all events.

### Command
Value object representing an intent. Passed to a command handler which loads the aggregate, calls methods, and stores resulting events. Commands carry `person_id` (from `current_person`), never `user_id`.

### User vs Person vs TenantUser
**User** = global Devise authentication identity. Credentials, sessions, `global_admin` flag. NOT tenant-scoped — a single User can belong to multiple tenants. **TenantUser** = tenant-scoped join record linking User to Tenant. Carries role within that tenant (`member` | `admin`) and an optional link to Person via `person_id`. **Person** = domain entity. Org chart position, manager. Events reference `person_id`. Controllers translate `current_user` → `current_tenant_user` → `current_person`.

### acts_as_tenant
Row-level multi-tenancy. All tenant-scoped ActiveRecord models have `tenant_id` and `acts_as_tenant :tenant`. Set per-request via `set_current_tenant_through_filter`. **User is NOT tenant-scoped** — it is a global identity. TenantUser, Person, and all projection read models are tenant-scoped. Event store isolation is via stream name prefixes, not `acts_as_tenant`.

### EventStreamNaming
Helper module that constructs tenant-namespaced stream names. All code uses this — never hand-builds stream names.

### Solid Queue
Rails 8 default for background jobs. Powers RES async event handlers (notifications, async projections). Configured via `config/queue.yml`.

---

## Integration Concepts

### HRIS Adapter
Pluggable interface for syncing Person data from HiBob, BambooHR, etc. Maps external role titles → Framework roles/levels via configurable mapping in `Tenant.hris_config`. Creates/updates Person records. Does NOT create User records.

### Notification Handler
RES async handler (ActiveJob) dispatched via Solid Queue. Sets tenant context from event metadata, then sends via configured adapter (Slack, Teams, email).

### ExternalReference
Value object on Evidence. `system` (github, jira, linear, slack, etc.), `url`, `external_id`, `metadata` (jsonb). Enables traceability to source systems.
