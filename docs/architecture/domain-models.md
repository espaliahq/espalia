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

### Setting history

Every change to two settings leaves a row in `tenant_setting_changes`: the setting, its new value and when. `Tenant` writes the row in the save that changes the setting, so the two commit together. Rows are never changed; a saved row is read-only.

| Setting | Read by |
|---|---|
| `time_zone` | `OrgFactPeriod.known_on` and `OrgGraph::ChangesBetween`, through `Tenant#end_of_day_then`: a past day ends in the zone in force at the end of it |
| `min_group_size` | No reader. It is a record only: every report, a closed cycle's included, uses today's size, so a row explains why a closed cycle's report changed |

A day before a tenant's first row reads the first row's zone, as that is what was known to be in force. The migration that created the table wrote each tenant's values that day, dated from the tenant's creation. Today's zone is read only for a tenant with no rows at all. Reads of today use today's zone.

A closed cycle's report uses today's size, so an admin who changes it changes closed cycles' reports too. Lowering it shows groups those reports hid until then; raising it hides groups they showed. The rows record when each change happened.

A recorded size must be a whole number: the model and a check constraint refuse anything else.

**The limit.** `update_column`, `update_all` and raw SQL that change either setting skip the callback and leave no row, so the record misses the change, and a past day would end in the old zone after the new one took over. The recorded write check and the `Espalia/WritesMustBeDeclared` cop guard those, and nothing else does (see [direct-writes.md](direct-writes.md)). A save that skips validation with no whole size, such as a blank one, fails as a whole: the record refuses the row, and the tenant is left as it was.

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

`global_admin` makes an account an admin in every tenant. Every change to it leaves a row in `global_admin_changes`: the account's id, the new value, where the change came from and when. `User` writes the row in the save that changes the flag, so the two commit together. Every check on the source runs before the write, so the row can fail only in the database, and Postgres then aborts the whole transaction, flag included. The save locks the account's row and reads the stored flag first, so a copy loaded before another change, saving the value already stored, records nothing: one change, one row.

A save that changes the flag must name its source first. Without one, a validated save fails with an error on `global_admin_source`, and a save that skips validation raises `User::GlobalAdminSourceMissing`. Either way the refusal comes before the write, so nothing is saved:

| `source` | Set by |
|---|---|
| `admin_task` | `bin/rails admin:create` |
| `seed` | `SeedAdmin.bootstrap!` |
| `console` | An operator changing the flag by hand: `user.update!(global_admin: false, global_admin_source: "console")` |
| `baseline` | Only the migration that created the table, one row for each account that held the flag then. The model refuses it. |

A saved row is read-only, so the model can't change, destroy or delete it. A row holds no tenant, name or email, and no foreign key, so it outlives its account. Forgetting a person unlinks their account in that tenant but keeps the global `users` row, so the audit still points at it and adds nothing of its own. Devise's cancel-account route (`DELETE /users`) deletes an account, as does a delete by hand; either way its rows keep an id that names nobody.

**The limit.** `update_column`, `update_columns`, `update_all`, `insert_all`, `upsert_all` and raw SQL skip the callbacks and leave no row. Three things guard them, and nothing else does. The recorded write check fails on a write to `users` from a file `config/write_ownership.yml` doesn't name. The `Espalia/WritesMustBeDeclared` cop flags a persistence call in an undeclared file (see [direct-writes.md](direct-writes.md)). Neither can tell which column a declared file writes. A database check constraint refuses any `source` outside the list, so raw SQL that writes a row can't invent one.

The same holds for the audit table itself. The class-level `delete`, `delete_by`, `delete_all`, `update_all`, `insert_all` and `upsert_all`, and raw SQL, on `global_admin_changes` skip the read-only guard. Only the write-ownership check and the cop stand in their way, as `app/models/user.rb` is the one declared writer.

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
