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

Structure — roles and levels:
  RoleFamilyAdded { id, name, description }
  RoleFamilyUpdated { id, name?, description? }
  RoleAdded { role_family_id, id, name, code, track }
  RoleUpdated { id, name?, code?, track? }
  LevelAdded { role_id, id, ordinal, title, code, is_entry }
  LevelUpdated { id, ordinal?, title?, code? }

Structure — capabilities:
  CapabilityCategoryAdded { id, name, description }
  CapabilityCategoryUpdated { id, name?, description? }
  CapabilityAdded { category_id, id, stable_id, name, description }
  CapabilityArchived { id, reason }

Structure — bindings and scoring:
  CapabilityRoleBindingCreated { id, capability_id, role_id, weight, individual_tolerance? }
  CapabilityRoleBindingUpdated { id, weight?, individual_tolerance? }
  CapabilityRoleBindingRemoved { id }
  ScoringThresholdsConfigured { framework_id, mastery_threshold?, promotion_score_threshold?,
                                overperformance_cap?, deficit_threshold? }
  NOTE: Events retain legacy field names (individual_tolerance, promotion_score_threshold).
  The projection maps these to the current read model columns (deficit_threshold,
  meeting_expectation_threshold).
  All four scoring thresholds are configurable via the framework settings UI
  (GET/PATCH /frameworks/:id/settings). Nil values revert to system defaults.

Content — expectations (canonical rated text):
  BehaviouralExpectationSet { id, stable_id, capability_id, level_id, description }
  BehaviouralExpectationUpdated { id, new_description, rationale }

Content — illustrations (role-specific clarifying examples, NOT rated):
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
  DraftVersionStarted { target_version, started_by }
    Opens draft phase implicitly on first structural change.
    Structural events between this and FrameworkVersionPublished
    only visible in draft projection (not published).
  MigrationMappingDefined { from_stable_id, to_stable_id,
                            mapping_type, requires_reassessment, reason }
    mapping_type: same | evolved | split | archived | new
  FrameworkVersionPublished { version, published_by }
    Closes draft. Published projection advances.
    Only Owner and Editor can publish.
```

---

## Projections

**Published Framework State** — Primary read model. Replays all events but **skips structural events between `DraftVersionStarted` and `FrameworkVersionPublished`**. Editorial changes apply immediately. What assessors, managers, and reporting see.

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

Structural changes (adding/removing capabilities, changing bindings) require a new version — NOT suggested edits.

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

**Structural changes** = new version. **Editorial changes** = suggested edits, no version.

**Implicit draft lifecycle:** The first structural change by any permitted collaborator implicitly opens a draft (emits `DraftVersionStarted`). No explicit "start draft" ceremony needed. All collaborators (`collaborator` role and above) can see the draft state. Only `owner` and `editor` can publish.

**Versioning workflow:**
1. First structural change → `DraftVersionStarted` emitted automatically
2. Structural events accumulate, published projection unaffected
3. System diffs published vs draft to derive migration mappings
4. Admin reviews, emits `MigrationMappingDefined` events
5. `FrameworkVersionPublished` (by Owner or Editor) → published projection advances
6. Completed assessments: preserved via event replay to prior `FullAlignmentCompleted`
7. In-progress assessments: `FrameworkVersionMigrated` in each affected person stream

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
