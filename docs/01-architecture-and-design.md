# Career Growth Framework — Architecture & Design

> **Stack:** Rails 8 · RailsEventStore ~> 2.16 · PostgreSQL · Solid Queue · Devise · acts_as_tenant

---

## 1. Purpose

An open-source, multi-tenant platform that operationalises career growth frameworks. Organisations define career paths and use the platform for self-assessments, manager alignments, evidence collection, and growth planning.

### 1.1 Nine Key Capabilities

| # | Capability |
|---|-----------|
| 1 | Role-based career paths with capability categories shared across roles or specific to one |
| 2 | Behavioural expectations per capability, per level, per role |
| 3 | Regular self-assessment and manager alignment (async, live, or record-only) with historical trend analysis |
| 4 | Evidence/feedback collection from self, managers, and peers — re-linkable between capabilities |
| 5 | Framework evolution over time without losing existing data |
| 6 | Differential capability weighting per role |
| 7 | Must-have vs flexible capabilities for performance and promotion |
| 8 | Growth plans with focus areas, regular check-ins, and freshness reporting |
| 9 | Aggregate gap reporting across roles |

---

## 2. Architectural Decisions

### ADR-1: Multi-tenancy — acts_as_tenant with row-level isolation

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

### ADR-2: Authentication — Global User + TenantUser join, separate from domain Person

**Decision:** Three-model architecture: `User` (global Devise identity), `TenantUser` (tenant-scoped membership with role), and `Person` (domain entity). A single User can belong to multiple tenants.

**Why:** They represent different concerns with different lifecycles:
- **User** = global authentication identity. Credentials, sessions, Devise modules. NOT tenant-scoped — a single User can belong to multiple tenants. Has a `global_admin` flag for platform-level administration.
- **TenantUser** = tenant-scoped join record linking a User to a Tenant. Carries the user's role within that tenant (`member` | `admin`) and an optional link to the Person domain entity.
- **Person** = domain entity. Org chart position, manager. Source of truth for "who did what" in event streams. May be synced from HRIS.

Not every Person has a User (HRIS-imported people not yet invited). Not every User has a Person (tenant admins who configure but aren't assessed).

```ruby
# app/models/user.rb — Global identity (NOT tenant-scoped)
class User < ApplicationRecord
  devise :database_authenticatable, :registerable, :recoverable,
         :rememberable, :validatable

  has_prefix_id :usr

  has_many :tenant_users, dependent: :destroy
  has_many :tenants, through: :tenant_users

  attribute :global_admin, :boolean, default: false
end

# app/models/tenant_user.rb — Tenant-scoped membership
class TenantUser < ApplicationRecord
  acts_as_tenant :tenant
  has_prefix_id :tnu

  belongs_to :tenant
  belongs_to :user
  belongs_to :person, optional: true

  ROLES = { member: "member", admin: "admin" }
  enum :role, ROLES, default: :member

  validates_uniqueness_to_tenant :user_id
end

# app/models/person.rb — Domain entity
class Person < ApplicationRecord
  acts_as_tenant :tenant
  has_prefix_id :per

  translates :name
  belongs_to :manager, class_name: "Person", optional: true
  has_many :direct_reports, class_name: "Person", foreign_key: :manager_id, dependent: :nullify
  has_one :tenant_user, dependent: :nullify
  has_one :user, through: :tenant_user
end
```

The controller boundary resolves tenant from session and translates to `current_person`:

```ruby
class ApplicationController < ActionController::Base
  before_action :authenticate_user!
  set_current_tenant_through_filter
  before_action :set_tenant

  def current_tenant_user
    @current_tenant_user ||= current_user.tenant_users.find_by(tenant: ActsAsTenant.current_tenant)
  end
  helper_method :current_tenant_user

  def current_person
    @current_person ||= current_tenant_user&.person
  end
  helper_method :current_person

  private

  def set_tenant
    tenant = Tenant.find_by(id: session[:current_tenant_id])
    set_current_tenant(tenant)
  end
end
```

Domain-facing code (commands, events, projections) references `person_id`, never `user_id`.

### ADR-3: Event sourcing — RailsEventStore for Framework and Person Development

**Decision:** Event-sourced via RES `AggregateRoot` module for Framework and Person Development. Standard ActiveRecord for Tenant and Person.

**Why the split:**
- **Framework** accumulated hand-rolled event patterns (change logs, before/after snapshots, staleness detection, suggestion workflows). The collaborative editing requirement (inline suggested edits, Google Docs-style) was the tipping point — the event stream IS the collaboration history.
- **Person Development** unifies Assessment + Evidence + GrowthPlan as one continuous stream per person. Evidence, ratings, conversations, and growth plans are events in the same narrative. An "assessment" is a projection.
- **Person and Tenant** are CRUD entities. Event sourcing would add complexity without benefit.

**RES configuration:**

```ruby
# config/initializers/rails_event_store.rb
Rails.configuration.to_prepare do
  event_store = RailsEventStore::JSONClient.new(
    repository: RailsEventStoreActiveRecord::EventRepository.new(serializer: JSON),
    dispatcher: RubyEventStore::ComposedDispatcher.new(
      RubyEventStore::ImmediateAsyncDispatcher.new(
        scheduler: RailsEventStore::ActiveJobScheduler.new(serializer: JSON)
      ),
      RubyEventStore::Dispatcher.new
    )
  )

  # Synchronous projections (same transaction)
  event_store.subscribe(
    Frameworks::Projections::PublishedState.new,
    to: Frameworks::Events.all_content_events
  )
  event_store.subscribe(
    PersonDevelopment::Projections::CurrentAssessment.new,
    to: PersonDevelopment::Events.all_rating_events
  )
  event_store.subscribe(
    PersonDevelopment::Projections::GrowthPlan.new,
    to: PersonDevelopment::Events.all_growth_events
  )
  event_store.subscribe(
    PersonDevelopment::Projections::EvidenceCollection.new,
    to: PersonDevelopment::Events.all_evidence_events
  )

  # Async handlers (via Solid Queue)
  event_store.subscribe(
    Integrations::Notifications::AssessmentNotifier,
    to: [PersonDevelopment::Events::SelfRated,
         PersonDevelopment::Events::FullAlignmentCompleted]
  )
  event_store.subscribe(
    Reporting::Projections::GapAnalysis,
    to: [PersonDevelopment::Events::FullAlignmentCompleted]
  )

  Rails.configuration.event_store = event_store
end
```

**Aggregate loading with snapshots:**

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

### ADR-4: Open-source core including SaaS control plane

**Decision:** Modular monolith. Domain modules don't depend on SaaS control plane infrastructure.

**Implementation:** The SaaS control plane (tenant provisioning, billing, SSO routing) is an open-source module within the same codebase. Domain modules have no dependency on it — the boundary is one-way.

### ADR-5: Event-sourced versioning (single stream, draft phase)

**Decision:** One event stream per framework. Versions are points in the stream. Draft phase bracketed by `DraftVersionStarted` / `FrameworkVersionPublished`. Published projection skips structural events during draft. Editorial changes flow independently.

**Why:** No "clone and publish" — the event stream IS the history. Point-in-time reconstruction is replay, not snapshots. The `FrameworkVersionMigrated` event in person streams marks the version boundary.

### ADR-6: Two-layer expectation model

**Decision:** `BehaviouralExpectation` (canonical, rated, one per Capability × Level) and `RoleIllustration` (clarifying examples, not rated, multiple per Capability × Role × Level).

**Why:** The me&u framework has a clear two-layer structure. Ratings are against the canonical expectation. Illustrations help interpretation per role. This separation means illustration edits are low-stakes (Tier 1 review) while expectation edits may trigger reassessment (Tier 3).

### ADR-7: Continuous suggested edits (not batched proposals)

**Decision:** Atomic, inline suggested edits. Applied immediately on approval. Announcements batched separately.

**Why:** Framework improvement is continuous. An illustration tweak shouldn't block on a canonical expectation review.

### ADR-8: Simplified versioning — merge as archive, general reassessment flag

**Decision:** No special merge migration type. `requires_reassessment` is the general mechanism. Nothing silently dropped.

**Why:** Merge = archive the sources. The `requires_reassessment` flag works for any change type (split, meaningful rewording, or any admin-determined reason). Archived capabilities with ratings surface for relink/dismiss.

### ADR-9: Capability scoping via bindings

**Decision:** Removed category-level `scope`. `CapabilityRoleBinding` is the source of truth for which roles a capability applies to.

**Why:** A binary scope was lossy. The binding model naturally supports cross-development / career mobility views.

### ADR-10: Semi-freeform evidence with external references

**Decision:** Typed `evidence_type` enum + `other` with custom label. Optional `ExternalReference` for GitHub, Linear, Slack, etc.

### ADR-11: Flexible alignment modes

**Decision:** Async comment threads, live collaboration, and record-only — all on the same data model.

### ADR-12: V1 integrations — HRIS, Slack/Teams, SSO/SAML

**Decision:** Pluggable adapters. HRIS creates/updates Person records. Notifications via RES async handlers → Solid Queue → adapter. SSO via Devise + OmniAuth with tenant-level config.

---

## 3. Domain Model

### 3.1 Aggregate Map

```
┌─────────────────────────────────────────────────────────────────────────┐
│ PLATFORM (cross-tenant)                                                 │
│  FrameworkTemplate (ActiveRecord, no acts_as_tenant)                    │
└─────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│ GLOBAL (not tenant-scoped)                                              │
│  ┌──────────┐                                                           │
│  │  User     │  Devise auth identity, global_admin flag                 │
│  │  (Devise) │  has_many :tenant_users / :tenants                       │
│  └──────────┘                                                           │
└─────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│ TENANT BOUNDARY (acts_as_tenant :tenant on all models below)            │
│                                                                         │
│  State-based (ActiveRecord)        Event-sourced (RES AggregateRoot)   │
│  ┌──────────┐ ┌──────────┐        ┌──────────────┐ ┌───────────────┐  │
│  │  Tenant   │ │  Person   │       │  Framework    │ │ Person Dev    │  │
│  │  (config) │ │  (org)    │       │  (blueprint)  │ │ (journey)     │  │
│  └──────────┘ └──────────┘        └──────────────┘ └───────────────┘  │
│                                                                         │
│  ┌────────────┐                    Projections (ActiveRecord read      │
│  │ TenantUser  │                   models, acts_as_tenant)             │
│  │ (membership)│                   ┌─────────────────────────────┐    │
│  └────────────┘                    │ FrameworkState::*            │    │
│                                    │ AssessmentState              │    │
│                                    │ GrowthPlanState              │    │
│                                    │ Reporting::*                 │    │
│                                    └─────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────────┘
```

---

### 3.2 Tenant (ActiveRecord)

```ruby
# Schema: tenants
#   id (uuid), name, slug (unique),
#   settings (jsonb) — theme customisation

class Tenant < ApplicationRecord
  has_many :tenant_users, dependent: :destroy
  has_many :users, through: :tenant_users
  has_many :people, dependent: :destroy

  store_accessor :settings,
    :primary_color, :primary_color_dark,
    :secondary_color, :secondary_color_dark,
    :nav_bg_color, :nav_bg_color_dark,
    :nav_fg_color, :nav_fg_color_dark,
    :font_family
end
```

Settings jsonb currently stores theme customisation (colours, font). Additional JSONB columns for `sso_config`, `hris_config`, and `notification_config` are planned for V1 integrations but not yet implemented.

### 3.3 User (Devise — Global Identity)

```ruby
# Schema: users
#   id (uuid), email (unique, global), encrypted_password,
#   global_admin (boolean, default: false),
#   reset_password_token, reset_password_sent_at, remember_created_at
#
# NOT tenant-scoped — a single User can belong to multiple tenants

class User < ApplicationRecord
  devise :database_authenticatable, :registerable, :recoverable,
         :rememberable, :validatable

  has_prefix_id :usr

  has_many :tenant_users, dependent: :destroy
  has_many :tenants, through: :tenant_users

  attribute :global_admin, :boolean, default: false
end
```

### 3.3b TenantUser (Tenant-scoped Membership)

```ruby
# Schema: tenant_users
#   id (uuid), tenant_id, user_id, person_id (nullable),
#   role (string, default: "member")
#   Unique index on [tenant_id, user_id]

class TenantUser < ApplicationRecord
  acts_as_tenant :tenant
  has_prefix_id :tnu

  belongs_to :tenant
  belongs_to :user
  belongs_to :person, optional: true

  ROLES = { member: "member", admin: "admin" }
  enum :role, ROLES, default: :member

  validates_uniqueness_to_tenant :user_id
end
```

TenantUser carries the user's role within a tenant and optionally links to a Person domain entity. The `person_id` association is the bridge between authentication (User → TenantUser) and domain (Person).

### 3.4 Person (ActiveRecord)

```ruby
# Schema: people
#   id (uuid), tenant_id, email,
#   name_translations (jsonb, json_translate),
#   manager_id (uuid, nullable, self-referencing)

class Person < ApplicationRecord
  acts_as_tenant :tenant
  has_prefix_id :per

  translates :name

  belongs_to :manager, class_name: "Person", optional: true
  has_many :direct_reports, class_name: "Person", foreign_key: :manager_id, dependent: :nullify
  has_one :tenant_user, dependent: :nullify
  has_one :user, through: :tenant_user
end
```

Additional fields planned for V1 integrations (e.g. `external_id`, `current_role_id`, `current_level_id`, `status`, `sync_metadata`) are not yet implemented.

### 3.5 Framework (Event-sourced via RES)

One RES stream per framework: `tenant-{tenant_id}/Framework-{framework_id}`

#### 3.5.1 Aggregate

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
    # See event list below for full set
  end
end
```

#### 3.5.2 Projected State (read models)

```ruby
# Projection tables (all have tenant_id, acts_as_tenant)

# framework_states: id, tenant_id, framework_id, name, current_published_version,
#                   draft_in_progress, draft_version
# framework_role_families: id, tenant_id, framework_id, name, description
# framework_roles: id, tenant_id, role_family_id, name, code, track
# framework_levels: id, tenant_id, role_id, ordinal, title, code, is_entry
# framework_capability_categories: id, tenant_id, framework_id, name, description
# framework_capabilities: id, tenant_id, category_id, stable_id, name, description, status
# framework_capability_role_bindings: id, tenant_id, capability_id, role_id, weight, requirement_type
# framework_behavioural_expectations: id, tenant_id, stable_id, capability_id, level_id, description
# framework_role_illustrations: id, tenant_id, stable_id, expectation_id, role_id, ordinal, description
# framework_collaborators: id, tenant_id, framework_id, person_id, role, scope_role_id
# framework_suggested_edits: id, tenant_id, framework_id, author_id, target_entity_type,
#                            target_entity_id, field, suggested_value, rationale,
#                            requires_reassessment, reassessment_reason, status,
#                            reviewed_by, reviewed_at, reviewer_comment

module FrameworkState
  class Framework < ApplicationRecord
    self.table_name = "framework_states"
    acts_as_tenant :tenant
  end
  class Role < ApplicationRecord
    self.table_name = "framework_roles"
    acts_as_tenant :tenant
  end
  # ... etc for all projection models
end
```

#### 3.5.3 Framework Events

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

Structure — bindings:
  CapabilityRoleBindingCreated { id, capability_id, role_id, weight, requirement_type }
  CapabilityRoleBindingUpdated { id, weight?, requirement_type? }
  CapabilityRoleBindingRemoved { id }

Content — expectations (canonical rated text):
  BehaviouralExpectationSet { id, stable_id, capability_id, level_id, description }
  BehaviouralExpectationUpdated { id, new_description, rationale }

Content — illustrations (role-specific clarifying examples, NOT rated):
  RoleIllustrationAdded { id, stable_id, expectation_id, role_id, ordinal, description }
  RoleIllustrationUpdated { id, new_description, rationale }
  RoleIllustrationRemoved { id, reason }
  RoleIllustrationReordered { expectation_id, role_id, new_ordering }

Suggested edits (collaborative editing):
  EditSuggested { id, target_entity_type, target_entity_id, field,
                  suggested_value, author_id, rationale,
                  requires_reassessment, reassessment_reason }
  SuggestionCommented { suggestion_id, author_id, content }
  SuggestionApproved { suggestion_id, reviewer_id, comment }
    → Triggers actual content-change event (e.g. BehaviouralExpectationUpdated)
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

#### 3.5.4 Framework Projections

**Published Framework State** — Primary read model. Replays all events but **skips structural events between `DraftVersionStarted` and `FrameworkVersionPublished`**. Editorial changes apply immediately. What assessors, managers, and reporting see.

**Draft / Editor View** — Replays ALL events to head. Includes pending structural changes and pending suggested edits inline. What framework editors see during draft phase.

**Point-in-Time Framework** — Replay to timestamp. "What did this expectation say at this date?" Eliminates snapshots on assessments.

**Change History** — Event stream filtered and formatted. Full audit with attribution.

#### 3.5.5 Suggested Edit Review Tiers

| Tier | Entity | Who can approve | Reassessment default |
|------|--------|----------------|---------------------|
| 1 (light) | RoleIllustration | Role Lead, Role Family Lead, Capability Lead, Category Lead, Editor, Owner | false |
| 2 (moderate) | Capability/Category description | Capability Lead, Category Lead, Editor, Owner | false |
| 3 (high) | BehaviouralExpectation | Capability Lead (for their cap), Category Lead, Editor, Owner | true (overridable) |

Structural changes (adding/removing capabilities, changing bindings) require a new version — NOT suggested edits.

#### 3.5.6 FrameworkCollaborator Roles

Eight roles with scoped permissions. A person can hold multiple roles; permissions are the union (additive, never subtractive).

| Role | Scope | Structural changes | Content edits | Manage bindings | Manage collaborators | See drafts | Suggest edits | Comment |
|------|-------|-------------------|-------------|----------------|---------------------|-----------|--------------|---------|
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

**Comments:** Any framework entity (role family, role, level, capability category, capability, expectation, illustration) can be commented on by anyone with `collaborator` role or above. `viewer` cannot comment.

#### 3.5.7 Versioning and Migration

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

### 3.6 Person Development (Event-sourced via RES)

One RES stream per person per framework: `tenant-{tenant_id}/PersonDev-{person_id}-{framework_id}`

#### 3.6.1 Person Development Events

```
Assignment:
  PersonAssignedToFramework { framework_id, role_id, level_id }
  RoleChanged { old_role_id, new_role_id, old_level_id, new_level_id, reason }

Evidence:
  EvidenceRecorded { id, capability_stable_id, level_id, source, evidence_type,
                     custom_type_label?, title?, content, external_reference?, author_id }
    source: self | manager | peer
    evidence_type: peer_feedback | project_outcome | code_review | design_review |
                   customer_feedback | incident_response | presentation | mentoring | other
    external_reference: { system, url?, external_id?, metadata? }
  EvidenceRelinked { evidence_id, old_capability_stable_id, old_level_id,
                     new_capability_stable_id, new_level_id, relinked_by, rationale }
  EvidenceWithdrawn { evidence_id, reason, withdrawn_by }

Assessment cycle:
  AssessmentCycleOpened { cycle_id, cycle_name, cycle_type, framework_version_id }
    cycle_type: regular | performance_review | promotion_review
  AssessmentCycleCompleted { cycle_id }

Self-assessment:
  SelfRated { capability_stable_id, level_id, comment }
  SelfRatingRevised { capability_stable_id, new_level_id, comment, rationale }

Manager assessment:
  ManagerRated { capability_stable_id, level_id, comment, rated_by }
  ManagerRatingRevised { capability_stable_id, new_level_id, comment, rationale }

Alignment:
  AlignmentConversationStarted { cycle_id, mode, started_by }
    mode: async | live | record_only
  AlignmentCommentAdded { capability_stable_id, author_id, content }
  CapabilityAligned { capability_stable_id, aligned_level_id, comment,
                      agreed_by_person, agreed_by_manager }
  FullAlignmentCompleted { cycle_id, summary_notes }
    ← SNAPSHOT POINT. All capabilities aligned for this cycle.

Growth plan:
  GrowthGoalSet { goal, goal_type, target_date, set_by }
    goal_type: close_gaps | next_level | career_mobility | skill_development
  GrowthGoalRevised { new_goal, new_goal_type?, new_target_date?, rationale, revised_by }
  FocusAreaAdded { id, title, capability_stable_id?, gap_identified,
                   success_criteria, action_plan, action_type?, added_by }
    action_type: on_the_job_70 | coaching_20 | training_10
  FocusAreaUpdated { focus_area_id, field, new_value, rationale, updated_by }
  FocusAreaStatusChanged { focus_area_id, old_status, new_status, evidence?, changed_by }
    status: not_started | in_progress | achieved | deferred
  FocusAreaRemoved { focus_area_id, reason, removed_by }
  FocusAreaReprioritised { new_ordering, reprioritised_by }
  GrowthPlanProposed { proposed_by }
  GrowthPlanAgreed { agreed_by_person, agreed_by_manager }
  GrowthPlanAgreementRevoked { reason, revoked_by }

Check-ins:
  CheckInRecorded { id, date, focus_areas_discussed, progress_notes,
                    feedback_provided, next_steps, recorded_by }
  CheckInAmended { check_in_id, field, old_value, new_value, amended_by, reason }

Quarterly reviews:
  QuarterlyReviewCompleted { review_notes, outcomes, next_quarter_direction, reviewed_by }
  GrowthPlanSuperseded { superseded_by_reason }

Framework migration:
  FrameworkVersionMigrated { old_version_id, new_version_id, capability_mappings }
  ReassessmentFlagged { capability_stable_id, reason }
  ReassessmentResolved { capability_stable_id, resolution, resolved_by }
  ArchivedCapabilityAcknowledged { capability_stable_id, action, relinked_to_stable_id? }
    action: relinked | dismissed
```

#### 3.6.2 Person Development Projections

All projection read models have `tenant_id` and `acts_as_tenant :tenant`.

**Current Assessment State** — Latest aligned/self/manager level per capability. Updated synchronously on rating events.

```ruby
# assessment_states table:
#   id, tenant_id, person_id, framework_id, capability_stable_id,
#   self_rated_level_id, manager_rated_level_id, aligned_level_id,
#   last_self_rated_at, last_aligned_at, migration_status, reassessment_reason
```

**Growth Plan State** — Current goal, focus areas, last check-in. Updated synchronously.

```ruby
# growth_plan_states table:
#   id, tenant_id, person_id, framework_id, goal, goal_type,
#   target_date, status, agreed_at, last_check_in_at
# growth_plan_focus_areas table:
#   id, tenant_id, growth_plan_state_id, capability_stable_id,
#   title, gap_identified, success_criteria, action_plan,
#   action_type, status, ordinal
```

**Evidence Collection** — All evidence for a person. Updated synchronously.

```ruby
# evidence_items table:
#   id, tenant_id, person_id, framework_id, capability_stable_id, level_id,
#   source, evidence_type, custom_type_label, title, content,
#   external_ref_system, external_ref_url, external_ref_id, external_ref_metadata,
#   author_id, link_status (active|superseded), created_at
```

**Freshness** — Derived from timestamps on above projections. Queryable for dashboards.

**Point-in-Time Assessment** — Replay to `FullAlignmentCompleted` event. No separate projection needed — it's on-demand replay.

---

### 3.7 Template Library (cross-tenant)

```ruby
# framework_templates table (NO tenant_id, NOT acts_as_tenant)
#   id, name, description, author_tenant_id (nullable),
#   published_at, tags (string[]), snapshot (jsonb)

class FrameworkTemplate < ApplicationRecord
  # NOT acts_as_tenant — cross-tenant resource
  belongs_to :author_tenant, class_name: "Tenant", optional: true
end
```

Fork operation: deserialise snapshot → emit `FrameworkCreated` + all structural/content events into a new tenant-scoped stream.

---

## 4. Reporting Read Models

Async projections (via Solid Queue), updated on relevant events.

### 4.1 Individual Capability Heatmap
Capability × Expected Level × Self-rated × Aligned. Colour-coded gap visualisation.

### 4.2 Trend Analysis
Time-series of aligned ratings per capability using `capability_stable_id` across versions.

### 4.3 Aggregate Gap Report
Per role: count below/at/above expected level per capability. Weighted by binding weights.

### 4.4 Promotion Readiness
People where aligned ≥ expected for all `must_have` AND multiple capabilities show next-level.

### 4.5 Growth Plan Freshness Dashboard
Per manager: reports with last check-in, plan status. >30 days amber, >60 red.

### 4.6 Evidence Density
Per person per capability: evidence count by source. Highlights sparse areas.

### 4.7 Career Mobility View
Current role vs target role: capability overlap, gaps, illustration differences.

---

## 5. Integration Architecture

### 5.1 HRIS Sync

Pluggable adapter interface. Implementations for HiBob, BambooHR, etc.

```ruby
# app/integrations/hris/base_adapter.rb
module Integrations::Hris
  class BaseAdapter
    def sync_people(tenant)
      raise NotImplementedError
    end
  end
end
```

Creates/updates Person records. Maps external role titles → Framework roles/levels via configurable mapping in `Tenant.hris_config`. Does NOT create User records — invitation is a separate flow.

### 5.2 Notifications

RES async handlers dispatched via Solid Queue. Adapter pattern for Slack, Teams, email.

```ruby
# app/contexts/person_development/async_handlers/assessment_notifier.rb
class PersonDevelopment::AsyncHandlers::AssessmentNotifier < ApplicationJob
  prepend RailsEventStore::AsyncHandler

  def perform(event)
    ActsAsTenant.with_tenant(Tenant.find(event.metadata[:tenant_id])) do
      case event
      when PersonDevelopment::Events::SelfRated
        notify_manager_of_self_assessment(event)
      when PersonDevelopment::Events::FullAlignmentCompleted
        notify_person_of_alignment_complete(event)
      end
    end
  end
end
```

### 5.3 SSO/SAML

Devise + OmniAuth. Tenant-level SSO config stored in `Tenant.sso_config`. Self-hosted mode supports local username/password. SaaS mode routes to tenant-specific IdP.

---

## 6. RES Event Store (Postgres-backed)

RES uses its own migrations. No custom event store tables needed.

```bash
rails generate rails_event_store_active_record:migration
rails db:migrate
```

This creates `event_store_events` and `event_store_events_in_streams` tables. Optimistic concurrency via stream version.

**Snapshot strategy:** Use `AggregateRoot::SnapshotRepository` with snapshots stored in a separate RES stream (`*_snapshots`). Snapshot at every `FrameworkVersionPublished` and `FullAlignmentCompleted`.

**RES Browser:** Mount for debugging (restricted to tenant admin in production):

```ruby
# config/routes.rb
Rails.application.routes.draw do
  authenticate :user, ->(u) { u.global_admin? } do
    mount RailsEventStore::Browser => "/res"
  end
end
```

---

## 7. Module Boundaries

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

---

## 8. Capability-to-Implementation Mapping

| # | Capability | Implementation |
|---|-----------|---------------|
| 1 | Role-based paths, shared/specific capabilities | `CapabilityRoleBinding` scopes capabilities to roles. `RoleFamily` groups related roles for mobility. |
| 2 | Behavioural expectations per cap/level/role | `BehaviouralExpectation` (canonical, rated) + `RoleIllustration` (clarifying, not rated). |
| 3 | Self-assessment + alignment with history | Person Development stream: `SelfRated` → `ManagerRated` → `CapabilityAligned` → `FullAlignmentCompleted`. Three alignment modes. Trend via `capability_stable_id`. |
| 4 | Evidence from self/manager/peers, re-linkable | `EvidenceRecorded` / `EvidenceRelinked` events. Semi-freeform types + `ExternalReference`. |
| 5 | Framework evolution | Event-sourced Framework with versioning. `stable_id` continuity. `requires_reassessment` flag. Nothing silently dropped. |
| 6 | Weighted capabilities | `CapabilityRoleBinding.weight` — per-role weighting in reporting projections. |
| 7 | Must-have vs flexible | `CapabilityRoleBinding.requirement_type` — `must_have` gates performance/promotion. |
| 8 | Growth plans + check-ins + freshness | Growth events in Person Development stream. `GrowthPlanState` projection. Freshness = `last_check_in_at` delta. |
| 9 | Aggregate gap reporting | `Reporting::GapAnalysis` async projection. Aggregates `aligned_level_id` vs expected across people per role. |
