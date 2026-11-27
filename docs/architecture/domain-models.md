# Domain Models — ActiveRecord (State-based)

> Read this when: working on Tenant, User, TenantUser, or Person models; adding auth or multi-tenancy logic; writing migrations for these tables.

---

## Aggregate Map

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

## Tenant

```ruby
# Schema: tenants
#   id (uuid), name, slug (unique),
#   theme — default | bento | custom
#   custom_theme (jsonb) — a Custom theme's role values: { "brand" => { "light" => "#…", "dark" => "#…" } }
#   settings (jsonb) — font_family

class Tenant < ApplicationRecord
  include Themeable

  has_many :tenant_users, dependent: :destroy
  has_many :users, through: :tenant_users
  has_many :people, dependent: :destroy
end
```

A tenant's theme is Default, the Bento preset, or Custom (ADR-23). Custom stores values only for the roles it overrides; a blank role, light or dark, falls back to Default's. The roles it can set are the ones `theme/roles.css` reads a `--tenant-*` hook for (`Themeable::CUSTOM_ROLES`). The font applies to Custom only; presets carry their own. Additional JSONB columns for `sso_config`, `hris_config`, and `notification_config` are planned for V1 integrations but not yet implemented.

---

## User (Devise — Global Identity)

```ruby
# Schema: users
#   id (uuid), email (unique, global), encrypted_password,
#   global_admin (boolean, default: false),
#   color_scheme (string: auto | light | dark, default: "auto"),
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

`color_scheme` is the person's own Auto / Light / Dark choice. It lives on User, not the tenant, so it follows them across tenants and no tenant can lock it. Auto follows the operating system; Light or Dark is written to `<html data-scheme>` (ADR-23).

### Global admin audit

`global_admin` makes an account an admin in every tenant. Every change to it leaves a row in `global_admin_changes`: the account's id, the new value, where the change came from and when. `User` writes the row in the save that changes the flag, so the two commit together.

A save that changes the flag must name its source first, or it raises `User::GlobalAdminSourceMissing` and nothing is saved:

| `source` | Set by |
|---|---|
| `admin_task` | `bin/rails admin:create` |
| `seed` | `SeedAdmin.bootstrap!` |
| `console` | An operator changing the flag by hand: `user.update!(global_admin: false, global_admin_source: "console")` |
| `baseline` | Only the migration that created the table, one row for each account that held the flag then. The model refuses it. |

A saved row is read-only, so the model can't change or destroy it. A row holds no tenant, name or email, and no foreign key, so it outlives its account. Forgetting a person unlinks their account in that tenant but keeps the global `users` row, so the audit still points at it and adds nothing of its own. Devise's cancel-account route (`DELETE /users`) deletes an account, as does a delete by hand; either way its rows keep an id that names nobody.

**The limit.** `update_column`, `update_all` and raw SQL skip the callback and leave no row. Three things guard them, and nothing else does. The recorded write check fails on a write to `users` from a file `config/write_ownership.yml` doesn't name. The `Espalia/WritesMustBeDeclared` cop flags a persistence call in an undeclared file (see [direct-writes.md](direct-writes.md)). Neither can tell which column a declared file writes. A database check constraint refuses any `source` outside the list, so raw SQL that writes a row can't invent one.

The same holds for the audit table itself. `delete_all`, `update_all` and raw SQL on `global_admin_changes` skip the read-only guard. Only the write-ownership check and the cop stand in their way, as `app/models/user.rb` is the one declared writer.

---

## TenantUser (Tenant-scoped Membership)

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

TenantUser carries the user's role within a tenant and optionally links to a Person domain entity. The `person_id` association is the bridge between authentication (User → TenantUser) and domain (Person). The link is recorded on the grants stream and written by its projection; change it with `TenantUser#link_to!` (see [authorization.md → Where the tenant role lives](../guidelines/authorization.md#where-the-tenant-role-lives)).

---

## Person (ActiveRecord)

```ruby
# Schema: people
#   id (uuid), tenant_id, name (string), email,
#   job_title, department, role_id, level_id,
#   external_id, hris_source, status, hris_raw_data (jsonb),
#   manager_id (uuid, nullable, self-referencing)

class Person < ApplicationRecord
  acts_as_tenant :tenant
  has_prefix_id :per

  belongs_to :manager, class_name: "Person", optional: true
  has_many :direct_reports, class_name: "Person", foreign_key: :manager_id, dependent: :nullify
  has_one :tenant_user, dependent: :nullify
  has_one :user, through: :tenant_user
end
```

---

## Controller Boundary (resolving tenant and person)

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

---

## Template Library (cross-tenant)

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
