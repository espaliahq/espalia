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

TenantUser carries the user's role within a tenant and optionally links to a Person domain entity. The `person_id` association is the bridge between authentication (User → TenantUser) and domain (Person).

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
