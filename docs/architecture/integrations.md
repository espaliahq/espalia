# Integration Architecture

> Read this when: working on HRIS sync, the feedback exchange, notification adapters, SSO/SAML, or any external system integration.
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

1. **Upsert** — fetch all employees with pagination, map via `ResponseMapper`, upsert `Person` records. Matches by `external_id` first, then falls back to email (adopts manually-created people). Collects `touched_person_ids`. An employee present with `isActive: false` is upserted with `status: "inactive"`.
2. **Manager resolution** — second pass, builds `external_id → Person` map, sets `manager_id` from `reportsTo.id`.
3. **Deactivation** — HRIS-sourced people not in the current response are marked `status: "inactive"`. Does not touch people from other HRIS sources.
   **3b. Offboarding** — enforces "inactive ⇒ no live participation": every inactive person (however they became inactive — Pass 1's `isActive: false`, Pass 3's absence, or a manual admin edit) still enrolled in an **open** cycle is withdrawn (`PersonUnenrolled` reason `left_company` — a person-scoped removal, never a cycle conclusion), then unassigned from their framework(s) (`PersonUnassignedFromFramework`). State-driven and idempotent, so each sync self-heals stragglers. Per-person errors are collected in `result[:errors]` without aborting the sync.
4. **Auto-link TenantUsers** — `TenantUser.where(person_id: nil)` is scanned; each is linked to a `Person` matching the user's email. This bridges Devise auth → Person domain entity.
5. **Framework assignment + reporting-manager recording** — dispatches one of four assignment commands per **active** touched person (see below), then records the reporting manager onto the person's stream. Inactive people are skipped (`result[:skipped_inactive]`) — Pass 3b owns them.

**Reactivation (seasonal / boomerang returnees)** is the normal new-hire path, not a special case: when the person reappears in the response, Pass 1 flips them back to `active`, Pass 5 re-assigns (their assignment row was removed at offboarding, so the initial-assignment branch fires a second `PersonAssignedToFramework` on the same PersonDevelopment stream), and `AutoEnrollNewAssignments` enrolls them into any open cycle with a fresh progress slate (plus prior-aligned-cycle rating seeds, if any).

The entire Pass 5 loop is wrapped in `Rails.configuration.event_store.with_metadata(tenant_id: tenant.id)` so the `CurrentAssessment` projection can resolve tenant context when writing read models.

**Reporting-manager recording (within Pass 5).** After the assignment dispatch, the loop calls `command_handler.record_reporting_manager(person_id, framework_id, person.manager_id, source: "hris")` for every touched person that **has a framework assignment** — run independently of whether the title-mapping branch above succeeded, so a re-managed person whose title later becomes unmapped still gets a fresh recording. The command is idempotent: a no-op when the recorded manager is unchanged or the person has no manager. This makes the reporting line a first-class fact on the PersonDevelopment stream (`ReportingManagerRecorded` → `RecordedReportingManager`), the authoritative source for manager-rating authority. A one-off `events:backfill_reporting_managers` rake task seeds existing streams from the live `Person.manager_id` before the Stage-2 hard guard ships.

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
  offboarded: Integer,    # inactive people withdrawn from open cycles + unassigned (Pass 3b)
  skipped_inactive: Integer, # inactive people excluded from framework assignment (Pass 5)
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

Unmapped titles are the primary feedback loop for refining `role_mappings`: the integrations page lists them (and anyone still on an assignment an earlier title gave them), `HrisSyncJob` logs the four skip sets as a warning, and tenant admins map a title from the page or through the `integrations_*` MCP tools. See [hris-integration.md](../guidelines/hris-integration.md#configuring-rolelevel-mappings).

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

## Slack

Installed per tenant (OAuth v2, `Tenant#connect_slack!`). Outbound: Noticed
notifications DM'd by `SlackDeliveryMethod` after the in-app copy's grace
period. Inbound: `/growthos feedback` and the "Feedback on this message"
shortcut open a modal whose submission records evidence as the Slack user —
identity by workspace id and the member's cached or email-resolved Slack id,
writes through the same `Operations::Assessments::RecordEvidence` the web and
MCP use, stamped `acting_via: slack`. A Person who has never signed in gets a
`FeedbackDraft` and a link that opens the hub's modal prefilled after their
first sign-in. The how-to, the trust model and the three-second rule are in
[docs/guidelines/slack-integration.md](../guidelines/slack-integration.md).

## Feedback exchange

A tenant can exchange named feedback with a peer feedback system (Chip is the first). Each side serves the feedback given in it and pulls the other's; nothing is pushed. `Tenant.feedback_exchange_config` holds the peer and its address, `Tenant.feedback_exchange_credentials` the two shared secrets (encrypted, one per direction). Every request, both ways, is HMAC-signed over its method, path, query and body, with a five-minute window, a replay claim in the cache and a 24-hour overlap when a secret rotates. The client (`FeedbackExchange::Client`) is Faraday with typed errors and no retries; inbound requests are authenticated by `FeedbackExchangeSignedRequest`, which also resolves the tenant from the signature. The signature scheme, the endpoints and how to verify a pair are in [docs/guidelines/feedback-exchange.md](../guidelines/feedback-exchange.md); the contract is [the protocol](../notes/feedback-exchange-protocol.md).

As consumer, `FeedbackExchange::SyncJob` (every 15 minutes, `HrisSyncJob`'s retry policy) pulls the peer's feed page by page; `FeedbackExchange::Importer` turns each record into unplaced evidence written as its real author (`acting_via: feedback_exchange`, dated by `given_at`), and the `feedback_exchange_imports` ledger records every outcome and skip reason. Imports are silent: the peer owns notifications, and imported feedback surfaces on the hub under "Feedback to place".

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

### Google sign-in (global)

Implemented today as a single global "Continue with Google" option on the sign-in page — not yet per-tenant SSO. The flow:

1. `omniauth-google-oauth2` strategy registered in [config/initializers/devise.rb](../../config/initializers/devise.rb); callback is `/users/auth/google_oauth2/callback`.
2. `User.from_google_omniauth(auth)` ([app/models/user.rb](../../app/models/user.rb)) refuses unverified emails, then resolves the identity in this order: `provider/uid` match → `email` match (backfills `provider`/`uid`) → cross-tenant `Person` lookup. When only a `Person` matches, a `User` AND its linking `TenantUser` are created in one transaction so the new identity lands in a usable tenant.
3. [`Users::OmniauthCallbacksController#google_oauth2`](../../app/controllers/users/omniauth_callbacks_controller.rb) translates the result into a Devise session or a flash refusal.

Credentials live under `google:` in `config/credentials.yml.enc`. The strategy is always registered (with placeholder values if credentials are absent) so the OmniAuth middleware is installed in test and fresh-dev environments.

### Auto-linking SSO users to Person records

[`ApplicationController#current_tenant_user`](../../app/controllers/application_controller.rb) auto-links a `TenantUser` to a `Person` by matching email when `person_id` is nil. This complements the HRIS sync's Pass 4 auto-link and gives instant linking on first login rather than waiting for the next scheduled sync. Google sign-in adds a third entry point: when a Google identity arrives for an email that exists as a `Person` but not yet as a `User`, the User+TenantUser are provisioned on the spot rather than waiting for either of the above.
