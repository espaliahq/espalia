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

## ADR-13: Authorization enforced in the command handler, not in controllers

**Decision:** Write-path authorization lives in the command handler (derived from aggregate state), not in Pundit policies in controllers. Controllers pass `author_id` and call the command handler; they never decide whether an action is permitted.

**Why:** Framework collaborators are part of the Framework aggregate — stored as events and rebuilt into aggregate state. Enforcing authorization at the controller level would duplicate state the aggregate already owns, and would allow bypassing checks from background jobs, admin tooling, or any other non-HTTP entry point. The aggregate is the single source of truth for who can do what.

**Auto-approval pattern:** When an authorized user (one where `framework.can_approve?(author_id)` returns true) submits an edit in `:editing` mode, the command handler immediately follows `EditSuggested` with `SuggestionApproved` and the resulting content-change event — three events, instant effect. Users without approval authority emit `EditSuggested` only; the suggestion stays pending until a reviewer acts. A future `mode: :suggesting` parameter lets authorized users explicitly create a pending suggestion for peer review regardless of their approval authority.

**Stub until collaborators land:** `can_approve?` currently returns `true` for all users. When the collaborator model is implemented (via `CollaboratorAdded` events), it will query `@collaborators[user_id]&.[](:role)` against the tier-appropriate approval roles.

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

This does not yet rewrite ratings in person streams — that's the `FrameworkVersionMigrated` cross-stream work tracked as a separate follow-up. For now, the enforcement prevents accidental orphaning at publish time and creates the audit trail (`MigrationMappingDefined` events) that the later cross-stream migration will consume.
