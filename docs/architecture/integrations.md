# Integration Architecture

> Read this when: working on HRIS sync, notification adapters, SSO/SAML, or any external system integration.
> For the how-to of configuring HRIS mappings or adding new providers, see [docs/guidelines/hris-integration.md](../guidelines/hris-integration.md).

---

## HRIS Sync

Multi-tenant, pluggable adapter that syncs employee data from external HRIS systems (HiBob today, BambooHR planned) into `Person` records, then assigns them to framework roles/levels via a configurable mapping table.

### Adapter layering

Four focused classes, each with one responsibility:

```
HrisSyncAllTenantsJob (recurring, every 6h)
  └─ HrisSyncJob (per tenant)
       └─ Hris::Hibob::Adapter (orchestrates 5-pass sync)
            ├─ Hris::Hibob::Client (HTTP + auth + pagination + retries)
            └─ Hris::Hibob::ResponseMapper (pure JSON → Person attrs)
```

- **`Hris::BaseAdapter`** — abstract interface with `sync_people`, `fetch_employees`, `provider_name`. New providers subclass this.
- **`Hris::Hibob::Client`** — Faraday-based HTTP client. Per-instance credentials (no global state). Handles cursor pagination, exponential-backoff retries, and raises typed errors (`AuthenticationError`, `RateLimitError`, `ApiError`).
- **`Hris::Hibob::ResponseMapper`** — pure data-mapping with no side effects. Transforms HiBob JSON into flat `Person`-compatible attribute hashes. Easy to test with fixtures.
- **`Hris::Hibob::Adapter`** — orchestrator that runs the 5-pass sync inside a transaction.

### Per-tenant credential storage

- `Tenant.hris_config` (JSONB) — typed via `HrisConfig` StoreModel: provider, `role_mappings`, `level_field_id`, `sync_enabled`, `last_synced_at`, webhook secret
- `Tenant.hris_credentials` (encrypted string) — `{"service_user_id", "api_token"}` JSON, encrypted via Rails ActiveRecord Encryption (keys in `Rails.application.credentials.active_record_encryption`)

No global singleton. The adapter reads both fields per tenant and constructs a fresh client each time.

### The 5-pass sync

`Hris::Hibob::Adapter#sync_people`:

1. **Upsert** — fetch all employees with pagination, map via `ResponseMapper`, upsert `Person` records. Matches by `external_id` first, then falls back to email (adopts manually-created people). Collects `touched_person_ids`.
2. **Manager resolution** — second pass, builds `external_id → Person` map, sets `manager_id` from `reportsTo.id`.
3. **Deactivation** — HRIS-sourced people not in the current response are marked `status: "inactive"`. Does not touch people from other HRIS sources.
4. **Auto-link TenantUsers** — `TenantUser.where(person_id: nil)` is scanned; each is linked to a `Person` matching the user's email. This bridges Devise auth → Person domain entity.
5. **Framework assignment** — dispatches one of four commands per touched person (see below).

The entire Pass 5 loop is wrapped in `Rails.configuration.event_store.with_metadata(tenant_id: tenant.id)` so the `CurrentAssessment` projection can resolve tenant context when writing read models.

### Role/level mapping

`HrisConfig.role_mappings` is an array of `HrisRoleMapping` StoreModel entries. Each maps one or more HRIS job titles to a framework role code, with an **optional** `level_ordinal`:

**Mode 1 — title carries the level:**
```ruby
HrisRoleMapping.new(
  hris_titles: ["Senior Software Engineer"],
  framework_role_code: "E",
  level_ordinal: 5   # explicit
)
```

**Mode 2 — level comes from a separate HRIS custom column:**
```ruby
HrisRoleMapping.new(
  hris_titles: ["Engineering Manager", "Senior Engineering Manager"],
  framework_role_code: "EM"
  # level_ordinal omitted → adapter reads person.hris_level_ordinal
)
```

Mode 2 requires `HrisConfig.level_field_id` to be set to the HRIS custom column ID (e.g. `"column_0000000000000"`). The `Client` automatically adds `work.customColumns.<level_field_id>` to the requested fields; the `ResponseMapper` extracts the human-readable value into `person.hris_level_ordinal`.

Both modes can be mixed within one tenant's config.

Resolution per person in Pass 5:
1. Look up normalized title (downcase + strip) in `role_mappings`. If not found → track in `result[:unmapped_titles]` and skip.
2. Look up role by code. If not in framework → track in `result[:missing_roles]` and skip.
3. `resolved_ordinal = mapping.level_ordinal || person.hris_level_ordinal`. If nil → track in `result[:missing_ordinals]` and skip.
4. Look up `FrameworkState::Level.find_by(role_id:, ordinal: resolved_ordinal)`. If nil → track in `result[:missing_levels]` and skip.
5. Look up existing `PersonFrameworkAssignment` and dispatch the right command (see next section).

Duplicate HRIS titles across mappings are rejected by `HrisConfig` validation (ambiguous).

### Reassignment events

`PersonDevelopment::Aggregate#assign_to_framework` raises if already assigned — it's the **initial** assignment event. Subsequent changes emit different events:

- **`PersonRoleChanged`** — transfers between roles. Carries `previous_role_id`, `new_role_id`, `previous_level_id`, `new_level_id`, `reason`. Because `level_id` is scoped to a role, switching roles always requires a new level.
- **`PersonLevelChanged`** — promotions within the same role. Carries `previous_level_id`, `new_level_id`, `reason`.

Aggregate commands: `change_role(new_role_id, new_level_id, reason:)` and `change_level(new_level_id, reason:)`. Both call `ensure_assigned!` and raise on "unchanged" transitions.

`CurrentAssessment` projection handles both events by updating the existing `PersonFrameworkAssignment` row (not replacing it). Assessment history (cycles, ratings) on the same person-development stream is untouched.

### Adapter Pass 5 branching

For each touched person, the adapter picks exactly one path:

| Condition | Command | Event | Counter |
|-----------|---------|-------|---------|
| No `PersonFrameworkAssignment` | `assign_to_framework` | `PersonAssignedToFramework` | `:assigned` |
| Same role, same level | skip | — | `:unchanged` |
| Different role (level also changes, role-scoped) | `change_person_role` | `PersonRoleChanged` | `:role_changed` |
| Same role, different level | `change_person_level` | `PersonLevelChanged` | `:level_changed` |

### Result telemetry

`sync_people` returns:

```ruby
{
  created: Integer,       # new Person rows in Pass 1
  updated: Integer,       # existing Person rows touched in Pass 1
  deactivated: Integer,   # people no longer in HRIS response (Pass 3)
  assigned: Integer,      # initial framework assignments (Pass 5)
  role_changed: Integer,  # transferred to new role (Pass 5)
  level_changed: Integer, # promoted in same role (Pass 5)
  unchanged: Integer,     # already matched Pass 5 target
  skipped_no_title: Integer,
  errors: Array<Hash>,    # per-person error details
  unmapped_titles: Set<String>,
  missing_roles: Set<String>,
  missing_levels: Set<Hash>,    # { code:, ordinal: }
  missing_ordinals: Set<Hash>   # { title:, code: }
}
```

Admins inspecting unmapped titles is the primary feedback loop for refining `role_mappings`.

### Scheduling

`config/recurring.yml` runs `HrisSyncAllTenantsJob` every 6 hours in production. That job enumerates tenants where `hris_config.configured?(tenant)` is true and enqueues a `HrisSyncJob.perform_later(tenant)` for each.

Retry/discard policy on `HrisSyncJob`:
- `RateLimitError` — retry with polynomial backoff, 5 attempts
- `ApiError` (5xx) — retry with polynomial backoff, 3 attempts
- `AuthenticationError` — discard (log and stop; needs human fix)

In development, `db/seeds.rb` runs the sync synchronously after seeding the framework so the dev database is fully populated.

### Webhooks (future)

`Hris::Hibob::WebhookValidator.valid?(payload:, signature:, secret:)` verifies HMAC-SHA512 signatures using `tenant.hris_config.webhook_secret`. No webhook controller exists yet — incremental sync is polling-only for V1.

---

## Notifications

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

Not yet implemented — subscriptions will be added to [config/initializers/rails_event_store.rb](../../config/initializers/rails_event_store.rb) as handlers are built.

---

## SSO/SAML

Devise + OmniAuth. Tenant-level SSO config stored in `Tenant.sso_config` (planned, not yet implemented). Self-hosted mode supports local username/password. SaaS mode routes to tenant-specific IdP.

### Auto-linking SSO users to Person records

[`ApplicationController#current_tenant_user`](../../app/controllers/application_controller.rb) auto-links a `TenantUser` to a `Person` by matching email when `person_id` is nil. This complements the HRIS sync's Pass 4 auto-link and gives instant linking on first login rather than waiting for the next scheduled sync.
