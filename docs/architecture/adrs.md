# Architectural Decision Records

> Read this when: making architectural decisions, understanding *why* things are built a certain way, evaluating trade-offs for new approaches.

---

## ADR-1: Multi-tenancy — acts_as_tenant with row-level isolation

**Decision:** `acts_as_tenant` gem with `tenant_id` on all tenant-scoped tables. Tenant set per-request via `session[:current_tenant_id]` / `set_current_tenant_through_filter`. `ActsAsTenant.current_tenant` available throughout request.

**Why:** Simplest operationally — single database, standard ActiveRecord, works for self-hosted and SaaS. Schema-per-tenant (Apartment) adds operational complexity. Database-per-tenant is overkill for v1.

**RES integration:** The event store tables (`event_store_events`, `event_store_events_in_streams`) are managed by RES and don't have `tenant_id` columns. Tenant isolation is achieved via tenant-namespaced stream names:

```ruby
# app/lib/event_stream_naming.rb
module EventStreamNaming
  def self.framework_stream(framework_id)
    "tenant-#{ActsAsTenant.current_tenant.id}/Framework-#{framework_id}"
  end

  def self.person_development_stream(person_id, framework_id)
    "tenant-#{ActsAsTenant.current_tenant.id}/PersonDev-#{person_id}-#{framework_id}"
  end
end
```

Every event is published with `tenant_id` in metadata:

```ruby
event_store.publish(event, stream_name: stream_name,
  metadata: { tenant_id: ActsAsTenant.current_tenant.id, actor_id: current_person.id })
```

Projection handlers set tenant context from event metadata:

```ruby
class Frameworks::Projections::PublishedState
  def call(event)
    ActsAsTenant.with_tenant(Tenant.find(event.metadata[:tenant_id])) do
      # acts_as_tenant scoping is now active for all AR queries
      handle_event(event)
    end
  end
end
```

---

## ADR-2: Authentication — Global User + TenantUser join, separate from domain Person

**Decision:** Three-model architecture: `User` (global Devise identity), `TenantUser` (tenant-scoped membership with role), and `Person` (domain entity). A single User can belong to multiple tenants.

**Why:** They represent different concerns with different lifecycles:
- **User** = global authentication identity. Credentials, sessions, Devise modules. NOT tenant-scoped — a single User can belong to multiple tenants. Has a `global_admin` flag for platform-level administration.
- **TenantUser** = tenant-scoped join record linking a User to a Tenant. Carries the user's role within that tenant (`member` | `admin`) and an optional link to the Person domain entity.
- **Person** = domain entity. Org chart position, manager. Source of truth for "who did what" in event streams. May be synced from HRIS.

Not every Person has a User (HRIS-imported people not yet invited). Not every User has a Person (tenant admins who configure but aren't assessed).

Domain-facing code (commands, events, projections) references `person_id`, never `user_id`.

---

## ADR-3: Event sourcing — RailsEventStore for Framework and Person Development

**Decision:** Event-sourced via RES `AggregateRoot` module for Framework and Person Development. Standard ActiveRecord for Tenant and Person.

**Why the split:**
- **Framework** accumulated hand-rolled event patterns (change logs, before/after snapshots, staleness detection, suggestion workflows). The collaborative editing requirement (inline suggested edits, Google Docs-style) was the tipping point — the event stream IS the collaboration history.
- **Person Development** unifies Assessment + Evidence + GrowthPlan as one continuous stream per person. Evidence, ratings, conversations, and growth plans are events in the same narrative. An "assessment" is a projection.
- **Person and Tenant** are CRUD entities. Event sourcing would add complexity without benefit.

---

## ADR-4: Open-source core including SaaS control plane

**Decision:** Modular monolith. Domain modules don't depend on SaaS control plane infrastructure.

**Implementation:** The SaaS control plane (tenant provisioning, billing, SSO routing) is an open-source module within the same codebase. Domain modules have no dependency on it — the boundary is one-way.

---

## ADR-5: Event-sourced versioning (single stream, draft phase)

**Decision:** One event stream per framework. Versions are points in the stream. Draft phase bracketed by `DraftVersionStarted` / `FrameworkVersionPublished`. `FrameworkCreated` implicitly bootstraps a v1 draft; subsequent drafts are opened explicitly via `start_draft` or **implicitly when a shape-changing suggestion is approved with no draft in progress** (the aggregate auto-opens a pending draft so the structural change has somewhere to land). Published projection skips **shape-changing** events during a draft (see ADR-16). **Editorial / shape-preserving** events flow independently and apply live. The aggregate enforces draft-presence for shape-changing direct commands via `ensure_draft_in_progress!`.

**Why:** No "clone and publish" — the event stream IS the history. Point-in-time reconstruction is replay, not snapshots. The `FrameworkVersionMigrated` event in person streams marks the version boundary. Moving the draft guard to the aggregate (rather than only the projection) closes a silent footgun where structural commands called outside a draft would mutate the published view directly, corrupting in-flight assessment cycles that froze a `framework_version` at define time.

---

## ADR-6: Two-layer expectation model

**Decision:** `BehaviouralExpectation` (canonical, rated, one per Capability × Level) and `RoleIllustration` (clarifying examples, not rated, multiple per Capability × Role × Level).

**Why:** The framework has a clear two-layer structure. Ratings are against the canonical expectation. Illustrations help interpretation per role. This separation means illustration edits are low-stakes (Tier 1 review) while expectation edits may trigger reassessment (Tier 3).

---

## ADR-7: Continuous suggested edits (not batched proposals)

**Decision:** Atomic, inline suggested edits. Applied immediately on approval. Announcements batched separately.

**Why:** Framework improvement is continuous. An illustration tweak shouldn't block on a canonical expectation review.

---

## ADR-8: Simplified versioning — merge as archive, general reassessment flag

**Decision:** No special merge migration type. `requires_reassessment` is the general mechanism. Nothing silently dropped.

**Why:** Merge = archive the sources. The `requires_reassessment` flag works for any change type (split, meaningful rewording, or any admin-determined reason). Archived capabilities with ratings surface for relink/dismiss.

---

## ADR-9: Capability scoping via bindings

**Decision:** Removed category-level `scope`. `CapabilityRoleBinding` is the source of truth for which roles a capability applies to.

**Why:** A binary scope was lossy. The binding model naturally supports cross-development / career mobility views.

---

## ADR-10: Semi-freeform evidence with external references

**Decision:** Typed `evidence_type` enum + `other` with custom label. Optional `ExternalReference` for GitHub, Linear, Slack, etc.

---

## ADR-11: Flexible alignment modes

**Decision:** Async comment threads, live collaboration, and record-only — all on the same data model.

---

## ADR-12: V1 integrations — HRIS, Slack/Teams, SSO/SAML

**Decision:** Pluggable adapters. HRIS creates/updates Person records. Notifications via RES async handlers → Solid Queue → adapter. SSO via Devise + OmniAuth with tenant-level config.

---

## ADR-13: Suggestion-approval authority derived from aggregate state

**Decision:** The authority that decides whether a submitted edit auto-applies — `framework.can_approve?(author_id, target_entity_type:)` — lives in the command handler, derived from the aggregate's collaborator state, not in controller-level Pundit policies. Every non-HTTP entry point (background jobs, MCP, admin tooling) gets the same enforcement for free.

**Why:** Framework collaborators are part of the Framework aggregate — stored as events and rebuilt into aggregate state. Enforcing approval routing at the controller level would duplicate state the aggregate already owns, and would allow bypassing checks from any non-HTTP entry point. The aggregate is the single source of truth for approval authority.

*Amended (defense in depth):* the original decision read "not in controllers". Practice has since layered Pundit on top rather than instead: controllers call `authorize` on every action and `Operations::*` classes run a `policy_check` (see [authorization.md](../guidelines/authorization.md), which lists "authorization is enforced in the command handler" as an anti-pattern when used *alone*). The aggregate remains authoritative for the approval-routing decision this ADR is about — who can approve what tier — while Pundit gates who may reach each surface at all.

**Auto-approval pattern:** When an authorized user (one where `framework.can_approve?(author_id, target_entity_type:)` returns true) submits an edit in `:editing` mode, the command handler immediately follows `EditSuggested` with `SuggestionApproved` and the resulting content-change event — three events, instant effect. Users without approval authority emit `EditSuggested` only; the suggestion stays pending until a reviewer acts. The `mode: :suggesting` parameter — originally sketched here as future work — is **implemented**: the web's Editing/Suggesting toggle and the `frameworks_suggest_{edit,create}` MCP tools pass it through `Operations::Frameworks::SuggestEdit` / `SuggestCreate`, letting authorized users explicitly land a pending suggestion for peer review regardless of their authority (see [framework-explorer.md](../guidelines/framework-explorer.md), "Editing vs Suggesting toggle").

**Collaborator model (shipped):** the "stub until collaborators land" note is obsolete — `can_approve?` queries `@collaborators` (folded from `CollaboratorAdded` / `CollaboratorRoleChanged` / `CollaboratorRemoved` events) against the tier-appropriate approval roles, falling back to permissive only when a framework has no collaborators at all (bootstrapping). Collaborator management itself is Operations-first: `Operations::Frameworks::{AddCollaborator,ChangeCollaboratorRole,RemoveCollaborator}` (`:in_app` approval — permission-changing).

---

## ADR-16: Shape-changing vs editorial event classification

**Decision:** Framework events are classified along a single axis — **shape stability** — that determines whether they are draft-gated or live:

- **Shape-changing** events alter the `(capability_stable_id, level_ordinal)` rating grid that in-flight assessment cycles depend on. They are **draft-gated** at the aggregate (`ensure_draft_in_progress!`) and deferred in the published projection until `FrameworkVersionPublished` triggers a rebuild.
  - `LevelAdded`, `LevelOrdinalChanged`, `CapabilityAdded`, `CapabilityArchived`, `CapabilityRoleBindingCreated`, `CapabilityRoleBindingRemoved`, `BehaviouralExpectationSet`
- **Shape-preserving / editorial** events rewrite or add content without changing the grid. They apply **live** regardless of draft state — no draft required, no version bump.
  - `RoleFamilyAdded`/`Updated`, `RoleAdded`/`Updated`, `LevelUpdated` (title/code/is_entry), `CapabilityCategoryAdded`/`Updated`, `CapabilityRoleBindingUpdated` (weight/tolerance), `BehaviouralExpectationUpdated`, all `RoleIllustration*` events
- **Dependent-editorial** events are shape-preserving but reference a parent that may be shape-changing (e.g. illustrations depend on expectations; `LevelUpdated` depends on a `Level` created via `LevelAdded`). These handlers tolerate a missing parent by silently skipping; the publish-time rebuild replays them in stream order after the parent has landed.

The `update_level` command is **split** into `update_level_details` (title/code/is_entry — editorial, live) and `change_level_ordinal` (ordinal — shape-changing, draft-gated) because one command cannot sit on both sides of the axis.

**Why:** The previous design conflated "changes that happen during a version bump" with "structural changes that affect ratings". In practice, the common flurry of feedback on a freshly published framework — typos, rephrasings, illustration additions, role/category renames — is shape-preserving and should integrate immediately. Forcing every minor fix through the draft/publish cycle blocks users from integrating feedback whenever a draft is open for an unrelated shape-changing change.

This classification unblocks the continuous-improvement workflow while preserving the strong guarantee that in-flight assessment cycles see a stable rating grid between published versions. It matches the continuous-suggested-edits principle of ADR-7 but applies it to the editorial path more broadly.

**Trade-offs:** Binding weight updates (`CapabilityRoleBindingUpdated`) are classified as editorial (live) per the current decision to match `configure_scoring_thresholds` semantics. This means scoring outcomes for in-flight cycles can change silently when a weight is edited. A future ADR may tighten this by routing weight changes through a suggestion/review trail; see follow-up `todos/binding-weight-review-trail.md`.

---

## ADR-17: Migration mappings are mandatory at publish

**Decision:** `publish_version` raises if any capability archived during the current draft (and that existed at the time `DraftVersionStarted` fired) lacks a corresponding `MigrationMappingDefined` entry for its `stable_id`. Any mapping type — `same`, `evolved`, `split`, `archived`, `new` — satisfies the requirement; the mapping's presence is the acknowledgement that the admin thought about what happens to orphaned ratings. Capabilities added AND archived within the same draft do not require a mapping (nothing from the previous version to migrate).

**Why:** Before this change, publishing a draft that archived a capability silently orphaned all `AssessmentLevelRating` rows referencing that capability's `stable_id`. In-flight cycles, which freeze their `framework_version` at define time, would carry ratings that became meaningless after publish with no signal to anyone. Making mappings mandatory at the publish boundary turns silent corruption into a loud failure at exactly the point where the admin has the context to act.

The aggregate tracks pending-mapping debt via `@archives_needing_mapping` (populated on `CapabilityArchived`, cleared on `MigrationMappingDefined`, reset on `DraftVersionStarted` / `FrameworkVersionPublished`). The check fires before the publish event is applied, so no state changes if the guard rejects.

**Update (PR #119, 2026-05-26):** The cross-stream rating/evidence/comment migration is now implemented. `Frameworks::SyncHandlers::FrameworkVersionMigrationSync` consumes the `MigrationMappingDefined` audit trail on every `FrameworkVersionPublished` and emits `PersonDevelopment::Events::FrameworkVersionMigrated` per affected person stream. `same`/`evolved` mappings re-key the rating/evidence/comment rows to the survivor `to_stable_id`; `archived`/`split` flag the ratings (via `migration_status`) and withdraw the evidence; `new` is a no-op. The activity feed expands each event into per-capability entries anchored to the survivor.

**Update (2026-09-11, merge on collision):** A `same`/`evolved` survivor may be a capability that already existed in the previous version — the publish-review screen offers every non-archived capability, and "absorbed into another capability" is the documented use of `evolved`. A person who rated both the retiring and the surviving capability at the same cycle and level therefore holds two rows that the re-key would collapse onto one natural key, and the first production publish to hit this failed with a unique violation (`idx_assessment_ratings_cycle_person_cap_level`), rolling the whole publish back. Both re-keying projections now **merge on collision**: `PersonDevelopment::Projections::CurrentAssessment#rekey_ratings` deletes the retiring row and keeps the survivor's own rating (it was made against the capability that continues to exist, so it is the least surprising record to keep; the `evolved` reassessment flag still lands on it); `EvidenceCollection#rekey_links` closes the retiring link as `framework_migration_merged` and keeps the survivor's link. No `CODE_VERSION` bump: a colliding publish could never commit before, so no persisted `FrameworkVersionMigrated` event replays differently.

**Update (PR following #119):** `AssessmentCycles::SyncHandlers::FrameworkVersionRollSync` advances each open cycle's `latest_framework_version` on every publish so the cycle row expresses the full version range (`framework_version` lower bound, `latest_framework_version` upper bound). The "immutable for the lifetime of the cycle" framing on `CycleDefined` predated this work — only the `framework_version` (define-time) is immutable; the cycle's effective range moves with framework publishes while it's open.

## ADR-18: Event attribution — two layers (provenance metadata + domain payload)

**Decision:** Every event carries attribution at two distinct layers.

1. **Provenance → RES metadata, universal and automatic.** `acting_via` (`web`/`mcp`/`hris`), `actor_id` (the acting Person, nil for system syncs), `client_application_id` (MCP), and `correlation_id` (one id per request / sync run) are seeded once at the request/job boundary by [`AuditMetadata`](../../app/services/audit_metadata.rb) and applied to *every* event with no per-handler wiring (`Operations::Base#call` wraps `perform`). `correlation_id` originates at the boundary — the Rails request id for web/MCP, the enqueuing job id (or a fresh uuid) for HRIS.
2. **Domain attribution → event payload, selective.** When the actor is also a first-class domain fact a read model surfaces, it is ALSO modelled as an explicit payload field + read-model column: `rated_by_id` (manager ratings), `aligned_by_id` / `cleared_by_id` (alignment), `assigned_by` / `changed_by` (person assignment + role/level changes) — joining the pre-existing `author_id` / `reviewer_id` / `started_by_id`.

**Why:** A prior audit found ~1/3 of events attributed and the rest blind — most acutely manager ratings, which rendered "Manager" with no identity even though a person's manager changes over time. Metadata closes the universal gap in one move (retroactive-safe — metadata is per-event); payload fields exist only where projections/UI consume them, because projections read `event.data`, not metadata, and metadata is absent on replay/rake paths.

**Consequences:** Adding a payload attribution field to an existing event is additive-safe; consumers MUST tolerate nil on historical events (fall back to a generic label, never crash). Pure structural framework events stay metadata-only. Full rule in [event-sourcing.md → Attribution invariant](../guidelines/event-sourcing.md). Shipped in PRs #136, #137.

## ADR-19: Assessments are immutable as-at-completion; assessed role/level/version are per-cycle facts

**Decision:** An assessment is read against the role, level, and framework version **in effect at the time of the assessment** — current for an open cycle, frozen as-at-completion for a finished one.

- **Assessed role/level is a per-cycle snapshot owned by the AssessmentCycle aggregate**, not derived from the person's live assignment. `PersonEnrolled` carries `role_id`/`level_id`; `ParticipantRoleLevelChanged` re-snapshots mid-cycle on a promotion/transfer **while the cycle is open** (guarded: cycle open + person enrolled, no-op when unchanged), issued by the `ParticipantRoleSync` cross-stream handler off PersonDev `PersonLevelChanged`/`PersonRoleChanged`. Projected to `assessment_cycle_enrollments.{role_id,level_id,level_ordinal}`. `PersonDevelopment::Scoring` reads this snapshot (via `Assessments::MatrixDataBuilder`) instead of the current assignment level, **gated to the same role** (a horizontal-move snapshot is left to the deferred role-aware renderer).
- **Framework version at completion** is captured on `FullAlignmentCompleted` (`framework_version`, tracked in the aggregate from the join version and advanced by any mid-cycle migration) and projected to `assessment_cycle_progress.aligned_framework_version`, so reporting can attribute a completed assessment to its version without replay.
- **Completed (aligned) assessments are frozen from framework-version migration.** Enforced at three layers: the PersonDev aggregate's `migrate_framework_version` raises if alignment is completed; `FrameworkVersionMigrationSync` skips participants whose current open cycle is aligned (so the guard never rolls back a publish); and `CurrentAssessment#handle_framework_version_migrated` skips re-keying/flagging rating rows of any cycle the person has aligned (replay-safe — the frozen set is read from `AssessmentCycleProgress`, owned by the same projection).

**Why:** Scoring previously read the person's *current* level live, so a promotion silently re-interpreted a closed cycle's ratings (an aspirational "some" at E(n+1) flipped to underperforming-at-E(n+1)). And version migration mutated completed cycles' ratings. A completed assessment is an immutable historical record; an in-progress one should track current reality.

**Consequences:**
- This **reverses migrate-forward for completed cycles** (migrate-forward remains correct for *open* cycles). `CurrentAssessment` `CODE_VERSION` was bumped to 3; the change requires a rebuild (`REBUILD_ON_DEPLOY=person_development/current_assessment`), which also retro-corrects any completed cycles earlier code over-migrated.
- Frozen completed-cycle ratings keep their as-at-completion `stable_id`s, so after a future `evolved` publish they won't match the current grid — a completed cycle then needs **as-at-completion rendering** to display correctly. The faithful mechanism is **replay-to-the-`FullAlignmentCompleted`-event position** (its global position reconstructs the framework graph + un-migrated ratings + role/level as they were). The captured `aligned_framework_version` is a reporting convenience, NOT sufficient for full fidelity — shape-preserving edits (renames, illustrations, bindings) apply unversioned, so only replay is exact.
- **Deferred (not built):** the as-at-completion renderer itself, and **role-aware rendering for horizontal moves** (rendering a closed cycle against its snapshot *role*'s matrix + un-orphaning ratings). Rare in alpha.

Shipped in PRs #139, #140, #141, #142.

## ADR-20: Cross-cycle seeding carries all prior ratings forward (per-cell precedence)

**Decision:** When a person enrols in a new cycle, seed from their **most recent prior participation** in the framework — aligned or not — with per-cell precedence: an agreed cell carries the aligned value into both sides; a never-agreed cell carries each perspective's own last value forward; a side that never rated stays empty (seeding records what existed, never fabricates agreement). Idempotency is per side, so a human-touched side is never overwritten while the other side can still seed.

**Why:** The original rule seeded only from a cycle that completed alignment. Its premise ("a partially-aligned cycle isn't a valid carry-forward baseline") justified refusing an imperfect baseline, but the alternative isn't a better baseline — it's blank, which throws away every rating both parties made and punishes a report for their manager's incomplete alignment. The Q3 2026 cohort surfaced this as apparent seeding "inconsistency": ~60% of participants started empty solely because their Q2 alignment was never formally completed. Most-recent-participation (rather than last-aligned) is lossless because seeding chains — an unaligned cycle already contains the previous aligned baseline plus whatever moved since.

**Consequences:**
- Carried (seeded, unconfirmed) values render distinctly per side — dashed-outline pill / lighter chip tint, per-side `self_rating_source` / `manager_rating_source` on the read model (`CurrentAssessment` CODE_VERSION 6, rebuild backfills) — and selecting the shown value **confirms** instead of untoggle-clearing (the popover Clear posts an explicit marker).
- Unilateral manager ratings now carry across a manager handover as the new manager's starting position; `source: "seeded"` + `seeded_from_cycle_id` keep the provenance honest (UI disclosure of the source cycle is a future affordance).
- Anchoring is accepted, consistent with the product's diff-your-growth philosophy; engagement stays legible because seeded events never trip `started`.
- Bulk enrollment moved to a background job — seeding volume made inline enrollment a request-timeout class.

**Amendment (post-ship):** completion signals mean *vetted this cycle*. The per-side Complete chips, "Ready to align" cue, and header "Assessment Complete" pill count only human-owned cells (`Assessments::LevelCoverage` excludes `*_rating_source: "seeded"`; `CurrentAssessment` CODE_VERSION 7 retro-cleared stamps earned by seeds alone). A side whose values are entirely carried reads **"To confirm"** (dashed amber chip). The hero/score still count carried values — data vs work-state, deliberately asymmetric.
