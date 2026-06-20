# Framework Aggregate

> Read this when: working on framework features (roles, capabilities, expectations, illustrations, suggested edits, versioning, collaborators); writing framework events, commands, projections, or command handlers.

One RES stream per framework: `tenant-{tenant_id}/Framework-{framework_id}`

---

## Aggregate

```ruby
# app/contexts/frameworks/aggregate.rb
module Frameworks
  class Aggregate
    include AggregateRoot

    def initialize
      @role_families = {}
      @capabilities = {}
      @expectations = {}
      @illustrations = {}
      @bindings = {}
      @collaborators = {}
      @pending_edits = {}
      @current_version = 0
      @draft_in_progress = false
      @draft_version = nil
      @added_during_draft = Set.new       # stable_ids added in current draft
      @archives_needing_mapping = Set.new # stable_ids awaiting a migration mapping
      @status = :new
    end

    # Command methods raise events via apply()
    # apply_* methods update internal state
  end
end
```

---

## Projected State (read models)

All projection tables have `tenant_id` and `acts_as_tenant :tenant`.

```ruby
# framework_states: id, tenant_id, framework_id, name, current_published_version,
#                   draft_in_progress, draft_version,
#                   mastery_threshold (decimal, nil = no gate),
#                   meeting_expectation_threshold (decimal, nil = default 0.9),
#                   overperformance_cap (integer, default 1),
#                   deficit_threshold (decimal, default 1.0)
# framework_role_families: id, tenant_id, framework_id, name, description
# framework_roles: id, tenant_id, role_family_id, name, code, track
# framework_levels: id, tenant_id, role_id, ordinal, title, code, is_entry
# framework_capability_categories: id, tenant_id, framework_id, name, description,
#                                   deficit_threshold (decimal, nil = inherit framework, 0 = must balance),
#                                   overperformance_cap (integer, nil = inherit framework)
# framework_capabilities: id, tenant_id, category_id, stable_id, name, description, status
# framework_capability_role_bindings: id, tenant_id, capability_id, role_id, weight,
#                                     deficit_threshold (decimal, nil = inherit category/framework,
#                                                       0 = no deficit allowed, N = max acceptable deficit),
#                                     overperformance_cap (integer, nil = inherit category/framework)
# framework_behavioural_expectations: id, tenant_id, stable_id, capability_id, level_ordinal, description
# framework_role_illustrations: id, tenant_id, stable_id, expectation_id, role_id, ordinal, description
# framework_collaborators: id, tenant_id, framework_id, person_id, role, scope_role_id
# framework_suggested_edits: id, tenant_id, framework_id, suggestion_id (unique),
#                            target_entity_type, target_entity_id, field,
#                            current_value, suggested_value, author_id, rationale,
#                            status (pending|approved|rejected|withdrawn),
#                            reviewed_by, reviewed_at, reviewer_comment
```

---

## Events

```
Lifecycle:
  FrameworkCreated { name, tenant_id }
  FrameworkForkedFromTemplate { template_id }

Events are classified along two axes (see ADR-16):
  • Shape-changing: alters the (capability_stable_id, level_ordinal) rating grid.
    Deferred in published view during a draft, replayed on publish.
  • Editorial / shape-preserving: does not alter the rating grid. Applies live
    regardless of draft state. Editorial events whose target row depends on a
    shape-changing parent skip silently if the parent isn't yet materialised,
    and are re-applied by the publish-time rebuild.

Shape-preserving — roles and levels (editorial / live):
  RoleFamilyAdded { id, name, description }
  RoleFamilyUpdated { id, name?, description? }
  RoleAdded { role_family_id, id, name, code, track }
  RoleUpdated { id, name?, code?, track? }
  LevelUpdated { id, title?, code?, is_entry? }     # ordinal not carried here

Shape-changing — roles and levels (draft-gated):
  LevelAdded { role_id, id, ordinal, title, code, is_entry }
  LevelOrdinalChanged { level_id, new_ordinal, previous_ordinal, reason }

Shape-preserving — capabilities (editorial / live):
  CapabilityCategoryAdded { id, name, description }
  CapabilityCategoryUpdated { id, name?, description? }

Shape-changing — capabilities (draft-gated):
  CapabilityAdded { category_id, id, stable_id, name, description }
  CapabilityArchived { id, reason }
    Requires a matching MigrationMappingDefined for the archived
    capability's stable_id before publish_version can succeed,
    unless the capability was also added in the same draft.

Shape-changing — bindings (draft-gated):
  CapabilityRoleBindingCreated { id, capability_id, role_id, weight, individual_tolerance? }
  CapabilityRoleBindingRemoved { id }

Shape-preserving — binding tuning (editorial / live):
  CapabilityRoleBindingUpdated { id, weight?, individual_tolerance? }
    Live-apply: weight/tolerance changes take effect immediately for
    in-flight cycles. Matches configure_scoring_thresholds semantics.
  ScoringThresholdsConfigured { framework_id, mastery_threshold?, promotion_score_threshold?,
                                overperformance_cap?, deficit_threshold? }
  NOTE: Events retain legacy field names (individual_tolerance, promotion_score_threshold).
  The projection maps these to the current read model columns (deficit_threshold,
  meeting_expectation_threshold).
  All four scoring thresholds are configurable via the framework settings UI
  (GET/PATCH /frameworks/:id/settings). Nil values revert to system defaults.

Content — expectations (canonical rated text):
  BehaviouralExpectationSet { id, stable_id, capability_id, level_id, description }
    Shape-changing: adds a cell to the (capability_stable_id, level_ordinal)
    grid. Draft-gated.
  BehaviouralExpectationUpdated { id, new_description, rationale }
    Shape-preserving (editorial). Applies live. Rewording the canonical
    expectation does not change which capability × level slot exists.

Content — illustrations (role-specific clarifying examples, NOT rated):
  All four illustration events are shape-preserving (editorial / live).
  They have a hard dependency on their parent BehaviouralExpectation and
  are dispatched via the "dependent-editorial" path — live-applied when
  the parent exists, silently skipped and re-applied on rebuild otherwise.

  RoleIllustrationAdded { id, stable_id, expectation_id, role_id, ordinal, description }
  RoleIllustrationUpdated { id, new_description, rationale }
  RoleIllustrationRemoved { id, reason }
  RoleIllustrationReordered { expectation_id, role_id, new_ordering }

Suggested edits (collaborative editing):
  EditSuggested { suggestion_id, framework_id, target_entity_type, target_entity_id,
                  field, suggested_value, author_id, rationale }
  SuggestionAmended { suggestion_id, new_suggested_value, author_id, rationale }
    → Author updates their own pending suggestion in-place (preserves suggestion_id
       and any comment thread attached to it)
    → For a CREATE suggestion the new value is the revised primary content
       (description / name / title per CREATE_CONTENT_FIELD); on approval
       apply_suggested_creation folds new_suggested_value into that attribute so
       the entity is created with the amended value, not the original proposal.
  SuggestionCommented { suggestion_id, author_id, content }
  SuggestionApproved { suggestion_id, reviewer_id, comment }
    → Triggers actual content-change event (e.g. RoleIllustrationUpdated)
    → Competing pending suggestions on the same (target_entity_id, field)
       are automatically rejected with reason "Superseded by approved suggestion"
  SuggestionRejected { suggestion_id, reviewer_id, comment }
  SuggestionWithdrawn { suggestion_id }

Collaborator management:
  CollaboratorAdded { person_id, collaborator_role, scope_type?, scope_id? }
    collaborator_role: owner | editor | role_family_lead | role_lead |
                       capability_category_lead | capability_lead | collaborator | viewer
    scope_type: nil (framework-wide) | role_family | role | capability_category | capability
    scope_id: UUID of the scoped entity (nil for framework-wide roles)
  CollaboratorRoleChanged { person_id, old_role, new_role, scope_type?, scope_id? }
  CollaboratorRemoved { person_id, collaborator_role, scope_type?, scope_id? }

  A person can hold multiple collaborator roles on the same framework.
  Permissions are the union of all held roles — never subtractive.

Version lifecycle:
  DraftVersionStarted { target_version, started_by, auto_opened? }
    Emitted by: (a) FrameworkCreated bootstraps a v1 draft automatically
    (started_by: "system"); (b) explicit start_draft command for v2+;
    (c) approve_suggestion for a shape-changing suggestion when no draft
    is in progress — auto-opens a pending draft (auto_opened: true,
    started_by: the approver's person_id).
    Shape-changing events between this and FrameworkVersionPublished are
    only visible in the draft projection (not published). Editorial events
    apply live to both projections regardless of draft state.
  MigrationMappingDefined { from_stable_id, to_stable_id,
                            mapping_type, requires_reassessment, reason }
    mapping_type: same | evolved | split | archived | new
    Any mapping for an archived capability's stable_id satisfies the
    publish-time enforcement (see ADR-17).
  FrameworkVersionPublished { version, published_by }
    Closes draft. Published projection rebuilds by wiping child read models
    and replaying the entire stream. Publish is rejected if any capability
    archived in this draft (and that existed at draft start) lacks a
    MigrationMappingDefined entry.
    Only Owner and Editor can publish.
```

---

## Projections

**Published Framework State** — Primary read model. Routes events by shape classification: **shape-changing** events are skipped while `draft_in_progress` is true and replayed on `FrameworkVersionPublished`; **editorial** events apply immediately regardless of draft state. On publish, `destroy_framework_children` wipes child read models and `handle()` replays every event from the stream — this is the single replay path. What assessors, managers, and reporting see.

**Draft / Editor View** — Replays ALL events to head. Includes pending structural changes and pending suggested edits inline. What framework editors see during draft phase.

**Point-in-Time Framework** — Replay to timestamp. "What did this expectation say at this date?" Eliminates snapshots on assessments.

**Change History** — Event stream filtered and formatted. Full audit with attribution.

---

## Suggested Edit Review Tiers

| Tier | Entity | Who can approve | Reassessment default |
|------|--------|----------------|---------------------|
| 1 (light) | RoleIllustration | Role Lead, Role Family Lead, Capability Lead, Category Lead, Editor, Owner | false |
| 2 (moderate) | Capability/Category description | Capability Lead, Category Lead, Editor, Owner | false |
| 3 (high) | BehaviouralExpectation | Capability Lead (for their cap), Category Lead, Editor, Owner | true (overridable) |

**Shape-changing** changes (adding/removing capabilities, changing level ordinals, creating/removing bindings, setting new expectations) require a new version — they accumulate in a draft and become visible on publish. **Shape-preserving** editorial changes (renames, rephrasings, illustrations, binding weight tweaks) apply immediately via either suggestion-approval or direct editorial commands, independent of draft state.

---

## Collaborator Roles

Eight roles with scoped permissions. A person can hold multiple roles; permissions are the union (additive, never subtractive).

| Role | Scope | Structural changes | Content edits | Manage bindings | Manage collaborators | See drafts | Suggest edits | Comment |
|------|-------|-------------------|-------------|----------------|---------------------|-----------|--------------|---------||
| `owner` | Framework-wide | Yes | Yes | Yes | Yes | Yes | Yes | Yes |
| `editor` | Framework-wide | Yes | Yes | Yes | No | Yes | Yes | Yes |
| `role_family_lead` | Their family + exclusively-bound caps | Yes | Yes | For family's roles | Within family | Yes | Anywhere | Yes |
| `role_lead` | Their role + exclusively-bound caps | Yes | Yes | For their role | Within role | Yes | Anywhere | Yes |
| `capability_category_lead` | Their category | Yes | Yes | No | Within category | Yes | Anywhere | Yes |
| `capability_lead` | Their capability | Yes | Yes | No | Within capability | Yes | Anywhere | Yes |
| `collaborator` | Framework-wide (read + suggest) | No | No | No | No | Yes | Anywhere | Yes |
| `viewer` | Published view only | No | No | No | No | No | No | No |

**Exclusively-bound capability ownership:** If ALL `CapabilityRoleBinding` records for a capability point to roles within a single role family, the Role Family Lead automatically has Capability Lead-equivalent rights over that capability. Same for Role Lead if all bindings point to a single role. Cross-family capabilities require a Capability Lead, Category Lead, Editor, or Owner.

**Binding management is role-side owned:** Role Family Leads and Role Leads decide which capabilities are bound to their roles. Capability Leads cannot force bindings onto roles they don't own.

**Scoped collaborator management:** Scoped leads can add/remove collaborators within their scope (e.g., a Role Lead can add other collaborators for the same role).

**Comments:** Any framework entity can be commented on by anyone with `collaborator` role or above. `viewer` cannot comment.

---

## Versioning and Migration

**Shape-changing** changes = new version. **Shape-preserving / editorial** changes = live, no version bump. See ADR-16 for the classification rationale.

**Draft lifecycle:**
- `FrameworkCreated` bootstraps a v1 draft automatically (emits `DraftVersionStarted(target_version: 1, started_by: "system")`). The caller populates the framework with structural content and calls `publish_version` to produce v1.
- Subsequent drafts are opened explicitly via `start_draft(target_version, started_by)`. Only `owner` and `editor` can publish.
- **Auto-opened drafts:** When a shape-changing suggestion (e.g. create capability, archive capability, create level, set behavioural expectation) is approved and no draft is in progress, the aggregate implicitly emits `DraftVersionStarted(target_version: current+1, started_by: approver, auto_opened: true)` before applying the structural event. Subsequent approvals join the same draft. The draft stays open until owner/editor publishes.
- Shape-changing **direct commands** (not via suggestion approval) still raise `"No draft in progress — call start_draft first"` if called outside a draft (enforced by `Frameworks::Aggregate#ensure_draft_in_progress!`).
- Editorial commands work regardless of draft state.

**Versioning workflow (v2+):**
1. Call `start_draft(target_version, started_by)` — emits `DraftVersionStarted`
2. Issue shape-changing commands; they accumulate in the stream but are deferred in the published projection
3. Issue any `define_migration_mapping(...)` calls for capabilities you're archiving
4. Call `publish_version(published_by)` — raises if archived capabilities lack mappings (see ADR-17); otherwise emits `FrameworkVersionPublished` and triggers a published-projection rebuild that replays every event in stream order
5. Completed assessments: preserved via event replay to prior `FullAlignmentCompleted`
6. In-progress assessments: `Frameworks::SyncHandlers::FrameworkVersionMigrationSync` emits `PersonDevelopment::Events::FrameworkVersionMigrated` on each affected person stream — ratings/evidence/comments follow the migration mappings to the survivor capabilities. See PR #119 and the per-mapping-type table below. UI for flagged ratings (relink/dismiss) remains follow-up.
7. Open cycles: `AssessmentCycles::SyncHandlers::FrameworkVersionRollSync` emits `AssessmentCycles::Events::FrameworkVersionRolled` on each open cycle's stream — the cycle's `latest_framework_version` advances so views and reports can express the full version range (`v1–v2`) the cycle was open across. Closed cycles are skipped; their range freezes at close time.

**Migration mapping types:**

| Type | Rating behaviour | Reassessment |
|------|-----------------|-------------|
| `same` | Carries forward | Default false |
| `evolved` | Carries forward | Default true |
| `split` | Blank, original as context | Always true |
| `archived` | ArchivedRating: relink or dismiss | N/A |
| `new` | Blank | N/A |

Assessment cannot reach `FullAlignmentCompleted` until all reassessments resolved and all archived ratings acknowledged.

---

## Repository (with snapshots)

```ruby
# app/contexts/frameworks/repository.rb
module Frameworks
  class Repository
    def initialize(event_store: Rails.configuration.event_store)
      @repo = AggregateRoot::SnapshotRepository.new(
        event_store,
        interval: 50  # snapshot every 50 events
      )
    end

    def with_framework(framework_id, &block)
      stream = EventStreamNaming.framework_stream(framework_id)
      @repo.with_aggregate(Aggregate.new, stream, &block)
    end
  end
end
```
