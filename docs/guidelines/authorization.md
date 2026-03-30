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

| Role | Scope | Structural | Content | Bindings | Manage Collab | See Drafts | Suggest | Comment |
|------|-------|-----------|---------|----------|---------------|-----------|---------|---------|
| `owner` | Framework-wide | Y | Y | Y | Y | Y | Y | Y |
| `editor` | Framework-wide | Y | Y | Y | N | Y | Y | Y |
| `role_family_lead` | Role family | Y | Y | For family | Within family | Y | Y | Y |
| `role_lead` | Role | Y | Y | For role | Within role | Y | Y | Y |
| `capability_category_lead` | Category | Y | Y | N | Within category | Y | Y | Y |
| `capability_lead` | Capability | Y | Y | N | Within capability | Y | Y | Y |
| `collaborator` | Framework-wide | N | N | N | N | Y | Y | Y |
| `viewer` | Published only | N | N | N | N | N | N | N |

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
| Manager rating | Person's direct manager (`assessee.manager_id == person.id`) |
| View assessment | Person OR their manager |
| Growth plan | Person proposes, manager agrees |

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
    collaborator_roles.with_edit_rights.exists?
  end
end
```

The concern provides: `collaborator_roles`, `has_any_collaborator_role?`, `can_publish?`, `can_manage_collaborators?`, `can_approve_tier?(tier)`.

## Key Files

| File | Purpose |
|------|---------|
| `app/models/authorization_context.rb` | Value object wrapping User + TenantUser + Person |
| `app/policies/application_policy.rb` | Base policy — default deny, `tenant_admin?`, `tenant_member?` |
| `app/policies/framework_policy.rb` | Framework access + collaborator-based edit/publish |
| `app/policies/assessment_policy.rb` | Person/manager assessment access |
| `app/policies/concerns/framework_collaborator_permissions.rb` | Reusable collaborator role queries |
| `app/read_models/framework_state/collaborator.rb` | Collaborator read model with role scopes |
| `app/controllers/application_controller.rb` | Identity chain helpers, `pundit_user`, `rescue_from` |

## Anti-patterns

```ruby
# Bad — manual role check instead of Pundit
before_action :authorize_admin!
def authorize_admin!
  redirect_to root_path unless current_user.global_admin? || tenant_user&.admin?
end

# Bad — delegating auth to command handler (it won't check)
# "Authorization is enforced in the command handler" — don't do this

# Bad — querying policies in views
def view_template
  if FrameworkPolicy.new(auth_context, @framework).admin?  # wrong
    render_admin_ui
  end
end

# Good — receive permission flag from controller
def initialize(framework:, is_admin:)
  @framework = framework
  @is_admin = is_admin
end
```
