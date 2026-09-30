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

**Update (2026-09-11, merge on collision):** An `evolved` survivor may be a capability that already existed in the previous version — the publish-review screen offers every non-archived capability, and "absorbed into another capability" is the documented use of `evolved`. A person who rated both the retiring and the surviving capability at the same cycle and level therefore holds two rows that a re-key would collapse onto one natural key, and the first production publish to hit this failed with a unique violation (`idx_assessment_ratings_cycle_person_cap_level`), rolling the whole publish back. Both re-keying projections now **merge on collision, losslessly**: `PersonDevelopment::Projections::CurrentAssessment#rekey_ratings` re-keys the non-colliding rows and leaves each colliding row under the retiring stable id flagged `capability_merged` — the same mechanism `archived`/`split` use, so nothing is deleted, the relink/dismiss UI covers merges for free, and the read model stays consistent with the aggregate (which never re-keys its rating maps). `EvidenceCollection#rekey_links` closes a colliding retiring link as `framework_migration_merged`, first reviving the survivor link if it had been removed so the item is never withdrawn as orphaned. When two retiring capabilities map onto one survivor, mappings apply in definition order (`created_at`, then `mapping_id`): the first is re-keyed, later ones merge. `same` carries no survivor by contract (`DefineMigrationMapping` forbids one) and is a no-op in every projection; a capability mapped onto itself is rejected by the operation, and a historical self-mapping replays as before (no re-key, flag only). Known gap: the `counts` baked into the `FrameworkVersionMigrated` payload for the activity feed are computed before the merge, so a merged cell is still counted as "carried". No `CODE_VERSION` bump: a colliding publish could never commit before, so no persisted event replays differently.

**Update (PR following #119):** `AssessmentCycles::SyncHandlers::FrameworkVersionRollSync` advances each open cycle's `latest_framework_version` on every publish so the cycle row expresses the full version range (`framework_version` lower bound, `latest_framework_version` upper bound). The "immutable for the lifetime of the cycle" framing on `CycleDefined` predated this work — only the `framework_version` (define-time) is immutable; the cycle's effective range moves with framework publishes while it's open.

**Update (2026-09-14, background publish):** `Operations::Frameworks::PublishVersion` now *requests* a publish rather than performing one: it pre-checks the ADR-17 gate (so a missing mapping is an immediate refusal, not a failure notification later), records a `FrameworkPublication` (plain ActiveRecord coordination state — one unfinished row per framework via a partial unique index on `finished_at IS NULL`, abandoned rows reaped after `STALE_AFTER`) and enqueues `Frameworks::PublishVersionJob`. The job re-authorizes as the requester (their TenantUser rebuilds the same `AuthorizationContext` the web uses, so revoked rights are refused at run time), runs `publish_version`, and closes the record on every exit — success, domain refusal, or unexpected error — before notifying the requester (`framework_published`). Because the web confirm and the MCP in-app approval both dispatch the same operation, both share the lock and the "Publishing…" state. The header's draft pill and Publish button are cleared by the `FrameworkVersionPublished` projection broadcast, whoever published. Known trade-off: edits landing between the request and the job run are published with the draft; the job's gate check turns a newly unmapped archive into a reported failure rather than a partial publish.

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
- **Deferred (not built):** the as-at-completion renderer itself. **Role-aware rendering for horizontal moves** (rendering a closed cycle against its snapshot *role*'s matrix + un-orphaning ratings) is resolved by ADR-22: a role reads the ratings its scope contains, so nothing needs re-keying.

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

## ADR-21: Level-independent scoring scale (100 = the assessed level, 200 = the next level)

**Decision:** The assessment score is a single scale read the same way at every level of every role: **1.0 = meeting the assessed level** (every bound capability consistent there, weighted), **1.5 = halfway to the next level**, **2.0 = demonstrating the next level in full — promotion ready**. Below 1.0 the number is the share of the assessed level demonstrated.

- **Bands, not ladders.** `score = current + next + (prior − 1)`, each part normalised over the capabilities that carry a behavioural expectation at that level (`expectation_cells`). Prior levels pool into one bucket the size of a single band (their attainment is averaged, so one deficit's share shrinks with the number of prior levels — deliberate).
- **A per-binding progression gate.** Credit above the assessed level is discounted per capability by that capability's own current-level frequency — multiplicative for a flexible binding, a step for a Required one (resolved tolerance 0). Making up *across* capabilities stays allowed; the per-capability deficit threshold and the category gates bound it.
- **The cap is a window of levels** (default 1 → a 2.0 ceiling); gated credit is monotone along the chain, so the window is also the most a capability can earn.
- **Defaults**: mastery 1.50 (the halfway waypoint, previously 1.15), deficit tolerance 0.75 (previously 1.0 — a value the gate could never exceed), meeting 0.95 and underperforming 0.80 unchanged but now level-independent. Ordering `underperforming < meeting < mastery` is validated by the Operation and the aggregate.
- **New state** `:top_of_ladder` for a meeting score with no level above.

**Why:** The previous ratio divided by the weight of every level up to the person's, with unrated past levels assumed consistent. That padding made the same number mean different things at different levels: the ceiling collapsed from 200% at L1 to 114% at L7 (mastery at 1.15 was unreachable at L7 and at the top), the 95% meeting bar tolerated a 5% band deficit at L1 but 35% at L7, and the promotion gate needed 95% of the next band at L1 but 65% at L7 (a seeded L7 read "Eligible for promotion" at 111% while demonstrating 65% of L8). The blocking gate never fired at its default, `mastering?` and `level_verdict` could disagree on one page, and the calibration cohort view compared people at different levels on an axis that meant nothing across them.

The gate exists because without one, next-level credit masks current-level gaps within the same capability — the seeded L2 engineer at 68% of L2 read 118% ungated. "Consistent at L+1 but most of the time at L" on one capability is rater noise in a cumulative framework, not strength. The mandatory case is a step because a multiplicative gate lets a Required capability at "most of the time" with "consistently" above net to zero, never block, and defeat the one rule written for it.

**Consequences:**
- Nothing persists a score, verdict or state; every surface re-renders on read, closed cycles included (the ADR-16 precedent for live threshold changes). Production had no configured ratio thresholds at cut-over (checked read-only, 2026-09-16); the deficit default moved with a migration on the NOT NULL column.
- Mastery on the new scale means "more than halfway to the next level"; the label is a display concern (a tenant-configurable word is a follow-up, #415).
- The hero, settings copy and the calibration cohort axis read the new scale (#412); capability and category altitudes (#413) and the in-surface explanation (#414) follow. The framework-wide deficit tolerance is now nullable (nil = system default), so the default lives in one constant and a rebuild reproduces the read model; the migration nils only rows whose stream never configured a tolerance.
- A tenant that had explicitly configured `mastery_threshold` or `meeting_expectation_threshold` under the old ratio keeps those numbers, which now mean something different (1.15 is 15% into the next band); none existed in production at cut-over, and the settings page shows any such value as custom with the new default beside it.
- The state-word thresholds keep their names; tests that pinned the old arithmetic (1.33, 1.083) were rewritten around the scale's invariants (1.0 / 1.5 / 2.0 at every level).

## ADR-22: A rating is a fact about the person at a capability × level; roles choose which facts count

**Decision:** A rating belongs to the person at one `(capability_stable_id, level_ordinal)` cell, never to a role. A role is a *reader*: its bindings and expectations define which cells count when you read the person as that role (`Assessments::RoleScope`). Manager ratings are disclosed to the assessee per role — a cell's manager and aligned values become visible only once alignment has started against a role whose scope contains it.

- **One truth per cell.** `BehaviouralExpectation` is canonical per capability × ordinal; role illustrations bring it to life and are never what is rated. A rating made while reading another role's examples on a shared cell *is* the home rating. There is no second rating scope for reading a person against another role or level (a *lens*).
- **Scope belongs to the reader, never the write.** Every reader filters by the role it is reading for, through `AssessmentLevelRating.within(scope)`; an unscoped read announces itself with `.across_all_roles`. A `via_role_id` stamp may record where a rating was made, for provenance only — it never decides whether the rating counts.
- **The guard is mechanical.** One `RoleScope`, one `.within`, the `GrowthOs/RatingsMustBeRoleScoped` cop, and an "ignores ratings outside the assessed role" test per reader.
- **Disclosure, freeze and completion are per role.** Starting alignment against a role discloses and freezes that role's cells; a cell is frozen once any started role's scope contains it; "Mark alignment complete" counts only that role's current-level cells.
- **Writes still need an open cycle.** Between cycles a lens is read-only.
- **The lens is private; declaring is shared.** Reading a person through another role writes nothing and notifies nobody. Starting alignment against it, or declaring an exploration, is what the other party sees.
- **Self ratings and evidence keep today's visibility.** Neither is gated on alignment now, and a lens does not change that.
- **Below-level assumption uses the home level.** Scoring assumes "consistently" only below *both* the level being read and the home level, so reading an E2 as EM4 does not grant L3 for free.

**Why:** Ratings were always keyed without a role (`assessment_level_ratings` is `(cycle, person, framework, capability_stable_id, level_ordinal)`), so a role was already a reader in practice — but several readers never said which role they read for and counted raw rows filtered by ordinal alone. The first out-of-scope cell leaks into the home record, the cohort report and the calibration room; a framework migration that re-keys a rating onto a capability the role no longer binds produces one today. An earlier design gave a lens its own seeded rating scope so reading against PM examples couldn't move the E3 record; since ratings are against the expectation, there was nothing to protect, and a second scope would have fought the PersonDevelopment aggregate's single-current-cycle invariant.

**Consequences:**
- Out-of-scope cells are rated into the current cycle like any other, carried forward by ADR-20 seeding per cell, and need no reconciliation. A later role move starts warm.
- Every rating reader must choose a scope; the cop fails CI on one that doesn't. Write-side code (the projection, seeding, the migration sync) and natural-key single-cell reads are exempt by construction.
- Resolves ADR-19's deferred *role-aware rendering for horizontal moves*: a cycle is rendered against a role by scoping its ratings to that role, not by re-keying them.
- Alignment events gained a role (`AlignmentStarted{role_id, level_ordinal, cell_keys}`, `FullAlignmentCompleted{role_id}`, `AlignmentReopened{role_id}`). History has none of them and keeps its meaning: the home role's alignment over every cell. `assessment_cycle_progress.status` stays the home lifecycle every cohort reader uses; `assessment_cycle_role_alignments` holds each role's.
- Built in phases (plan: [role-lens-plan.md](../notes/role-lens-plan.md)): the scope guard (#439), the lens, per-role alignment and disclosure (a `CurrentAssessment` rebuild), and declared explorations.
