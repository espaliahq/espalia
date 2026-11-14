# Authorization Standards

## Identity Chain

Every request resolves a three-tier identity chain in `ApplicationController`:

```
current_user          → Devise User (global, not tenant-scoped)
  current_tenant_user → TenantUser (membership in active tenant, carries role)
    current_person    → Person (domain org-chart entity, optional)
```

These are cached per-request and available as controller helpers and view helpers. Pundit receives all three via `AuthorizationContext`:

```ruby
# ApplicationController
def pundit_user
  AuthorizationContext.new(
    user: current_user,
    tenant_user: current_tenant_user,
    person: current_person
  )
end
```

Policies access them via delegation:

```ruby
class ApplicationPolicy
  delegate :user, :tenant_user, :person, to: :context
end
```

## Two Permission Systems

### 1. Tenant Roles (TenantUser)

Flat, two-level membership on the `TenantUser` join record:

| Role | Access |
|------|--------|
| `member` | View tenant resources |
| `admin` | Full tenant administration |

Plus `User.global_admin?` for platform-level access.

Check via base policy helpers:

```ruby
def tenant_admin?  # global_admin OR tenant admin
  user&.global_admin? || tenant_user&.admin?
end

def tenant_member?  # any membership
  tenant_user.present?
end
```

### 2. Framework Collaborator Roles

Granular, scoped roles on `FrameworkState::Collaborator`. A person can hold **multiple roles** on the same framework — permissions are the **union** of all held roles (additive, never subtractive).

| Role | Scope | Structural | Content | Bindings | Manage Collab | Rename | See Drafts | Suggest | Comment |
|------|-------|-----------|---------|----------|---------------|--------|-----------|---------|---------|
| `owner` | Framework-wide | Y | Y | Y | Y | Y | Y | Y | Y |
| `editor` | Framework-wide | Y | Y | Y | N | N | Y | Y | Y |
| `role_family_lead` | Role family | Y | Y | For family | Within family | N | Y | Y | Y |
| `role_lead` | Role | Y | Y | For role | Within role | N | Y | Y | Y |
| `capability_category_lead` | Category | Y | Y | N | Within category | N | Y | Y | Y |
| `capability_lead` | Capability | Y | Y | N | Within capability | N | Y | Y | Y |
| `collaborator` | Framework-wide | N | N | N | N | N | Y | Y | Y |
| `viewer` | Published only | N | N | N | N | N | N | N | N |

**Rename** (`FrameworkPolicy#rename?`) is the framework's *identity*, not its
content, so it sits on the manage-collaborators bar — tenant admin or framework
owner — rather than the edit-rights bar the org-structure renames use. Like
those, it is a direct, shape-preserving edit (no suggestion path).

**Scope types:** `nil` (framework-wide), `role_family`, `role`, `capability_category`, `capability` — stored as `scope_type` + `scope_id` on the collaborator record.

**Key scopes on the read model:**

```ruby
FrameworkState::Collaborator::EDIT_ROLES
# => %w[owner editor role_family_lead role_lead capability_category_lead capability_lead]

scope :with_edit_rights   # roles that can directly edit
scope :with_publish_rights # owner + editor only
```

### Suggested Edit Approval Tiers

| Tier | Entity | Who Can Approve |
|------|--------|----------------|
| 1 (light) | RoleIllustration | Any edit-role holder |
| 2 (moderate) | Capability/Category description | owner, editor, capability_category_lead, capability_lead |
| 3 (high) | BehaviouralExpectation | owner, editor, capability_category_lead, capability_lead |

### Assessment Permissions

Access to person development streams is based on the person/manager relationship:

| Action | Who |
|--------|-----|
| Self-rating | Person themselves (`record.person_id == person.id`) |
| Manager rating | Recorded reporting manager **OR an active rating delegate** |
| View assessment | Person, **anyone in their manager chain** (direct, skip-level, …), **an active delegate**, **or a tenant/global admin** (HR view). Chain ancestors above the reporting manager and admins view read-only (static rating pills); delegates see alignment read-only |
| Start / complete / re-open alignment | Reporting manager only — never a delegate, the assessee, or an admin outside the chain. **Per role** (ADR-22): `start_alignment?(role_id:)`, `complete_alignment?(role_id:)`, `reopen_alignment?(role_id:)`; `role_id: nil` is the home role |
| Record an agreed value | Assessee or reporting manager, while some alignment is in progress (`create_alignment_rating?`); the cell must be one an in-progress alignment reads (checked per cell by the Operation) |
| Grant / revoke a rating delegation | Any ancestor manager (`Person#managed_by?`) or a tenant admin |
| Unassign from framework (`unassign?`) | Tenant admin only — a destructive org-structure change, not the assessee or their manager |
| Declare / close an exploration of another role (`start_exploration?` / `close_exploration?`) | The assessee, the reporting manager or an active delegate (`rating_participant?`) — no open cycle needed. View-only ancestors and admins outside the chain read it but can't declare or close |
| Growth plan | Person proposes, manager agrees |
| Read the free-text reasons on lifecycle events (`view_lifecycle_reasons?`): why someone was unenrolled, unassigned or moved, why a delegation was granted | The manager chain and tenant admins — not the assessee, and not a rating delegate outside the chain, though `show?` admits both |
| Report on a cycle (`AssessmentCyclePolicy#cohort?`, `attainment?`, `evidence_report?`) and list the cycles to report on (`report_index?` + `AssessmentCyclePolicy::Scope`) | Tenant admins see every cycle; anyone else the cycles with a non-withdrawn participant in their subtree. The scope and `cohort?` must agree, and a policy test holds them together |

**Recorded-authoritative manager.** `manages_assessee?` reads the reporting
manager captured on the PersonDevelopment stream
(`RecordedReportingManager.manager_id_for(person, framework)`) and falls back to
the live `Person.manager_id` only when nothing is recorded yet (manual /
non-HRIS tenant, or pre-backfill). This keeps Pundit and the aggregate's
manager-rating invariant deriving authority from one source so they can't
diverge. Deliberate trade-off: in an HRIS tenant a freshly promoted manager
can't rate until the next sync records them.

**Per-role alignment (ADR-22).** Alignment is started, completed and re-opened
against a role. For the home role (`role_id: nil`, or the home role's id) the
predicates read the participation's status exactly as before — start needs
`started`, complete `aligning`, re-open `aligned`. For another role they read
that role's `AssessmentCycleRoleAlignment` row: start needs a live participation
and no row yet (it does not wait for the home role), complete needs the row
`aligning`, re-open `aligned`. `view_alignment?(role_id:)` is true for another
role only once its row exists — the home role being `aligned` says nothing about
it. Pundit's `authorize` passes no arguments, so the Operations
(`Operations::Assessments::AlignmentLens#authorize_alignment!`) ask the per-role
predicates directly; the milestone controllers `authorize … :show?` and let the
Operation refuse.

**Freeze is per cell, not a policy gate.** `create_self_rating?` /
`create_manager_rating?` now ask only whether the participation still takes
ratings (a live one does, whatever the home status): a started alignment freezes
only the cells its role reads, so an aligning participation still takes ratings
on the cells a lens adds. The rating Operations refuse a frozen cell with the
reason (`RatingCell#refuse_frozen_cell!`), and the aggregate backs them.

**Delegated manager rating.** A reporting manager whose report is seconded into
another team can delegate the manager *rating* (not alignment) to someone closer
to the work. `create_manager_rating?` is `(manages_assessee? ||
active_rating_delegate?) && individual_ratings_editable?`;
`active_rating_delegate?` consults `ManagerAssessmentDelegation.active` (status +
non-expired). Alignment predicates stay `manages_assessee?`-only, so a delegate
rates but never starts, completes, or records alignment. Grant/revoke
(`delegate_manager_rating?` / `revoke_manager_rating_delegation?`) reuse the
manager-chain (`Person#managed_by?`) plus `tenant_admin?` — wider than the direct
manager because a skip-level or HR may set one up. Delegate writes are still
fully attributed (`rated_by_id`), and the rating event carries `via_delegation`.

### Org Graph Permissions

`OrgGraphPolicy` (authorize against `:org_graph`) says who may change units and
memberships. Every predicate that names a unit takes it as an argument, since
Pundit's `authorize` passes none.

| Action | Who |
|--------|-----|
| See the Org Graph (`show?`) | Any tenant member |
| The Units view, its activity sidebar and change it back, and `org_graph_units`, `org_graph_activity`, `org_graph_change_back` and `org_graph_change_back_group` (`show_units?`; a change-back also needs the rights to make the inverse change) | A tenant admin, until the Org Graph's screens are finished; it then opens to `show?` |
| Add, rename, reorder or remove the taxonomy's levels (`edit_taxonomy?`) | A tenant admin. Every unit sits at a level, so the taxonomy's shape is a bigger call than a unit edit |
| Providers, person facts and their confirmation, a root unit (`edit_structure?`, `create_unit?(nil)`) | A tenant admin or an Org Graph editor (`TenantUser#org_graph_editor`) |
| Rename, retire or own a unit, or add a unit beneath it (`edit_unit?`, `create_unit?(parent)`) | The above, or an active owner of that unit or any unit above it |
| Move a unit (`move_unit?(unit, new_parent)`) | Rights over the unit and over its new parent; a move to the root needs `edit_structure?` |
| Record a succession (`record_succession?(units)`) | Rights over every unit it names |
| Set, end or confirm a membership (`edit_membership?(member, unit)`) | Anyone in the member's manager chain, or whoever holds rights over the unit |
| Move a membership (`move_membership?(member, from, to)`) | The manager chain, or rights over both units |

Ownership inherits downward: owning Payments gives rights over every squad
beneath it, even one with owners of its own. Owners and managers lose their
rights once their `Person` is no longer active. A unit or person the Org Graph
doesn't hold is left to admins and editors, except that the manager chain can
still end a membership of a unit that is gone.

The commands check the policy too, as a second layer behind the controller's
own `authorize :org_graph, …`, which every action still calls. Every handler
names its actor. A person's context is checked against every command it runs,
and recorded as the person who made each change:

```ruby
OrgGraph::StructureCommandHandler.new(actor: pundit_user).rename_unit(unit_id, "Pay", effective_on:)
OrgGraph::CommandHandler.new(actor: pundit_user).set_membership(person_id, unit_id, provider:, effective_on:)
```

A refused command raises `OrgGraph::Authorization::Refused`, a
`Pundit::NotAuthorizedError` whose message names who may make the change.
`ApplicationController` handles it like any other refusal and shows its own
generic flash; a controller that wants the reason on screen rescues it and
shows `error.message`, as `Assessments::RatingsController` does.

A view that offers the changes asks `OrgGraphPolicy::UnitRights` which controls to draw
for one unit: rename, move and its parent choices, owners, members, each member's
destinations, and whether it may split, merge (and into which units) or retire. The unit drawer's controllers build it and pass it to the view, so the
view never asks the policy itself.

The system's own writes pass `OrgGraph::Authorization::SYSTEM`: the HRIS sync,
a retirement moving its members, the HRIS fact claim, a rake task. Nobody is
acting, so nothing is checked. A handler built with no actor, or with `nil`,
raises `ArgumentError`, so a screen that forgets to pass one fails instead of
skipping the check. Pass `SYSTEM` only where no person drives the write.
`TenantUser#ensure_person!` records a new person's stream as `SYSTEM` even when
an admin triggers it, since provisioning a person for an account is the
system's act and must never fail a member's sign-in.

### Team Planning Permissions

`PlanPolicy` says who may reach a plan. A plan holds pay and notes, so only its
members may: no other role opens one.

| Action | Who |
|--------|-----|
| Create a plan (`create?`) | A tenant admin, or a planner (`TenantUser#team_planner`, granted by an admin through `team_planning_add_planner`) |
| Open a plan, list its members, leave it (`show?`, `leave?`) | Its editors and viewers |
| Rename or delete it, add, re-role or remove its members (`update?`, `destroy?`, `manage_members?`) | Its editors |
| List frozen plans, delete one unread (`manage_frozen?`, `destroy_frozen?`) | A tenant admin, and only while the plan is frozen |

A member must be an active, unforgotten person, so a leaver or a forgotten
member loses their plans at once. A plan always keeps an editor: the aggregate
refuses to lose its last one, and the handler refuses to lose its last editor
who is still in the organisation. A plan whose editors have all left or been
forgotten is **frozen**: its viewers still read it and nobody changes it. A
tenant admin sees only its id, the day it froze and its viewer count, and may
delete it with a reason that `PlanDeleted` keeps.

To anyone outside a plan it reads as an unknown id, and `PlanPolicy::Scope`
lists only the caller's own plans. `test/integration/team_planning_privacy_test.rb`
walks every Team Planning tool as a tenant admin, an Org Graph editor, a
planner, a global admin and a plain member, and a new tool joins the walk on
its own.

## Policy Conventions

### File locations

```
app/policies/
  application_policy.rb                    # Base — default deny, tenant helpers
  framework_policy.rb                      # Framework CRUD + collaborator checks
  assessment_policy.rb                     # Person/manager access
  concerns/
    framework_collaborator_permissions.rb  # Reusable collaborator role resolution
```

### Naming

- One policy per resource: `FrameworkPolicy`, `AssessmentPolicy`
- Custom action names over generic CRUD: `create_illustration?`, `create_self_rating?`, `update_settings?`
- Convenience methods for views: `admin?` on FrameworkPolicy for conditional rendering

### Default deny

`ApplicationPolicy` denies all actions by default. Subclass policies explicitly opt in:

```ruby
class ApplicationPolicy
  def index?   = false
  def show?    = false
  def create?  = false
  def update?  = false
  def destroy? = false
end
```

### Collaborator permissions via concern

Include `FrameworkCollaboratorPermissions` in any policy that needs collaborator role checks:

```ruby
class FrameworkPolicy < ApplicationPolicy
  include FrameworkCollaboratorPermissions

  def create_illustration? = tenant_admin? || framework_collaborator_can_edit?

  private

  def framework_collaborator_can_edit?
    return false unless person.present?
    collaborator_roles.can_edit?
  end
end
```

The concern provides: `collaborator_roles`, `has_any_collaborator_role?`, `can_suggest?`, `can_publish?`, `can_manage_collaborators?`, `can_approve_tier?(tier)`.

**`collaborator_roles` is a loaded value object, not a relation.** A person holds
a handful of roles at most, and one edit-mode render asks several questions of
them (`edit?`, `edit_structure?`, `publish?`, plus
`Frameworks::SuggestionApprovalAuthority`'s tiers) — each of which used to be its
own `EXISTS`. `Frameworks::CollaboratorRoles.load` reads the roles once and
answers every predicate in memory; controllers that also build the approval
authority pass their loaded copy to it (`Frameworks::SuggestionAuthority
#framework_collaborator_roles`) so the request loads them exactly once. Add new
predicates to the value object rather than reaching for a scope + `exists?`.

## Impersonation ("view as another user")

A tenant admin can experience the system from another user's perspective. The design overrides the **lower two tiers** of the identity chain rather than swapping the Devise session: `current_user` stays the real admin, while `current_tenant_user` / `current_person` resolve to the impersonated target. Every policy and view then renders as the target sees it, automatically, because they all read from `pundit_user` / the identity chain.

Rules baked into the implementation:

- **Read-only.** Enforced at two layers — `ApplicationController` blocks unsafe HTTP methods while impersonating (`Impersonatable#enforce_impersonation_read_only`), and `Operations::Base` refuses any non-`:read` operation when `AuditMetadata`'s `impersonator_id` is set (the domain backstop). The impersonation, tenant-switch, and Devise controllers are exempt so the user can always stop, switch, or sign out.
- **Bulk exports are refused too, even though they are reads.** Both layers above let a GET / `:read` operation through, so an Operation that hands out data in bulk checks `AuditMetadata.current[:impersonation_active]` in its own `policy_check` and raises `Pundit::NotAuthorizedError` (`Operations::Reporting::FeedbackExport` is the example). Viewing as someone is for seeing what they see, not for walking off with a file under their identity.
- **Within-tenant, non-admin targets only.** `ImpersonationPolicy#create?` requires the actor to be a tenant admin and the target to be a same-tenant, non-admin, non-global-admin, non-self membership. The single load-bearing rule: **never impersonate someone with more privilege than yourself** (no escalation).
- **Authority is always the real admin.** The policy is evaluated against `Impersonatable#real_context`, never `pundit_user` (which is the impersonated context once active). It is **re-checked every request** — a revoked admin role or a target promoted to admin ends the session mid-flight, failing closed to the real admin's own view.
- **Auto-expiry.** A hard 30-minute TTL (`Impersonatable::TTL`), no refresh-on-activity. Also cleared on tenant switch and sign-out.
- **Audit.** While impersonating, events carry `actor_id` = the target and `impersonator_id` = the real admin, so the immutable stream names both identities (belt-and-suspenders, since writes are blocked).
- **Web-only.** MCP builds its `AuthorizationContext` from the token, never from session, so it ignores impersonation by construction — do not bridge them.

## Key Files

| File | Purpose |
|------|---------|
| `app/models/authorization_context.rb` | Value object wrapping User + TenantUser + Person |
| `app/policies/application_policy.rb` | Base policy — default deny, `tenant_admin?`, `tenant_member?` |
| `app/policies/framework_policy.rb` | Framework access + collaborator-based edit/publish |
| `app/policies/assessment_policy.rb` | Person/manager assessment access |
| `app/policies/concerns/framework_collaborator_permissions.rb` | Reusable collaborator role queries |
| `app/read_models/framework_state/collaborator.rb` | Collaborator read model with role scopes |
| `app/models/frameworks/collaborator_roles.rb` | One viewer's roles on one framework, loaded once and answered in memory |
| `app/controllers/application_controller.rb` | Identity chain helpers, `pundit_user`, `rescue_from` |
| `app/controllers/concerns/impersonatable.rb` | Impersonation session: context override, read-only guard, expiry, re-auth |
| `app/policies/impersonation_policy.rb` | `create?` — who a tenant admin may "view as" |
| `app/controllers/impersonations_controller.rb` | Start (`create`) / stop (`destroy`) impersonation |
| `app/components/shell/impersonation_banner.rb` | Sticky read-only banner shown while impersonating |

## Anti-patterns

```ruby
# Bad — manual role check instead of Pundit
before_action :authorize_admin!
def authorize_admin!
  redirect_to root_path unless current_user.global_admin? || tenant_user&.admin?
end

# Bad — delegating auth to command handler only 
# "Authorization is enforced in the command handler" — don't do this
# we want authorization to be enfored in controller and command handler for defense in depth

# Bad — querying policies in views
def view_template
  if FrameworkPolicy.new(auth_context, @framework).admin?  # wrong
    render_admin_ui
  end
end

# Good — controllers compute permissions via policy() and pass boolean flags to views
def initialize(framework:, is_admin:)
  @framework = framework
  @is_admin = is_admin
end
```
