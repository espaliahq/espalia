# HRIS Integration Standards

> How to work with HRIS adapters, configure role/level mappings per tenant, add new providers, and test the sync.
> For the architecture background, see [docs/architecture/integrations.md](../architecture/integrations.md).

## File structure

```
app/
  integrations/
    hris/
      base_adapter.rb                  # Abstract interface (Hris::BaseAdapter)
      field.rb                         # Hris::Field — one catalogue field: id, name, :list or :text
      dev_name_whimsifier.rb           # Dev-only deterministic name pseudonymizer
      hibob/
        client.rb                      # Hris::Hibob::Client — Faraday HTTP
        adapter.rb                     # Hris::Hibob::Adapter — 5-pass sync
        response_mapper.rb             # Hris::Hibob::ResponseMapper — pure mapping
        errors.rb                      # Hris::Hibob::Errors::{AuthenticationError,RateLimitError,ApiError,UnexpectedResponseError}
        webhook_validator.rb           # HMAC-SHA512 signature verification
  models/
    hris_config.rb                     # StoreModel for Tenant.hris_config
    hris_role_mapping.rb               # StoreModel — title → role + optional level
    hris_field_mapping.rb              # StoreModel — optional field-level overrides
  jobs/
    hris_sync_job.rb                   # Per-tenant background sync
    hris_sync_all_tenants_job.rb       # Recurring fan-out job
```

## Key conventions

- **No global state.** Every `Client` instance takes `service_user_id`, `api_token`, and optional `level_field_id` in the constructor. Adapters read `tenant.hris_secrets` (an `HrisCredentials` — its `inspect` never prints a value) per sync. Never use class-level config.
- **Credentials are set on the integrations page.** Provider, sync options and the write-only credential fields (service user id, API token, webhook secret) save through `Tenant#update_hris!` on `/tenant/integrations/hris` — a blank field keeps the stored value, and nothing echoes one. Secret writes are web-only (the feedback-exchange precedent): MCP keeps read-only status. **Disconnect** on the same page removes the credentials and turns the sync off, keeping the mappings (`Tenant#disconnect_hris!`).
- **Namespace style.** Use `class Hris::Hibob::X` not nested modules (per [rails-controllers.md](rails-controllers.md) style). The `app/integrations/` directory is a Zeitwerk root — files map to `Hris::*` directly (no `Integrations::` prefix).
- **Errors namespaced under `Errors` module.** Zeitwerk expects one constant per file; the errors module holds all error classes in a single `errors.rb`: `Hris::Hibob::Errors::AuthenticationError`.
- **Tenant metadata on RES commands.** When dispatching PersonDevelopment commands (assign/change role/change level) from an adapter, wrap the loop in `Rails.configuration.event_store.with_metadata(tenant_id: tenant.id)`. The projection reads this to set `ActsAsTenant` context.
- **Offboard on deactivation (Pass 3b).** An inactive person must hold no live participation: after Pass 3, the adapter withdraws every inactive person from any open cycle (`unenroll` reason `left_company` — a person-scoped removal, never `cycle_closed`, which is reserved for cycle conclusion) and removes their framework assignments. The sweep is state-driven and idempotent (it self-heals stragglers regardless of how the person became inactive), and Pass 5 skips inactive people. Reactivation needs no special handling — a returnee flows through the normal new-hire path (Pass 1 re-activates, Pass 5 re-assigns, auto-enroll picks them up). **New providers must implement the same offboarding sweep.**
- **Record the reporting manager.** Pass 5 also dispatches `record_reporting_manager(person_id, framework_id, person.manager_id, source: "hris")` for every touched person that has an assignment — independent of the title-mapping outcome, so a re-managed-but-unmapped person stays fresh. Like every other PersonDevelopment command above, it runs **inside the same `with_metadata(tenant_id: tenant.id)` block** (the Pass 5 loop is already wrapped) so the projection gets tenant context. Idempotent (no-op when unchanged or manager nil). This is the authoritative source for manager-rating authority (`RecordedReportingManager`); seed existing streams once via `bin/rails events:backfill_reporting_managers`. See [docs/guidelines/authorization.md](authorization.md#assessment-permissions).

## Development PII guard — whimsical pseudonyms

Dev environments sync against **real** HRIS accounts to validate the
integration, so `Hris::DevNameWhimsifier` (applied in the adapter's Pass 1,
development env only) deterministically replaces every person's name with a
whimsical pseudonym ("Clementine Puddleduck") before it touches the local
database. Key properties:

- **Deterministic** — the pseudonym is a pure function of the HRIS external id
  (SHA-256 → curated word lists), so re-syncs map the same employee to the
  same name, and the manager's name inside a report's `reportsTo` raw payload
  matches the manager's own record.
- **Uniform and collision-resistant** — lists are power-of-two sized (no
  modulo bias) and surnames are composed stem + ending (32 × 16 = 512), so
  duplicate surnames — which read as family relations — stay rare even for
  large orgs.
- **Covers the raw payload too** — `firstName` / `surname` / `displayName` are
  scrubbed in `hris_raw_data` (top level and `work.reportsTo`), not just the
  mapped `name`.
- **Emails are NOT scrambled** — TenantUser auto-linking (Pass 4) and SSO both
  match on email; changing them would break dev sign-in. Emails remain the one
  piece of real PII in a dev database.
- A dev database seeded before this guard existed still holds real names —
  re-running the sync (`bin/rails db:seed` or `HrisSyncJob`) rewrites them.
- Outside development `.call` is a pass-through; test/production data is
  untouched. Bump `DIGEST_PREFIX` to reshuffle all pseudonyms.
- **New providers must apply it too** — a future adapter (BambooHR, …) wraps
  its own mapped attrs the same way: `Hris::DevNameWhimsifier.call(attrs)`.

## Configuring role/level mappings

`Tenant.hris_config.role_mappings` is an array of `HrisRoleMapping` StoreModel entries.

**Tenant admins edit them on the HRIS integration page** (`/tenant/integrations/hris`): an "Unmapped titles" card lists every title active HRIS people hold that no mapping covers, and a shared modal maps, remaps or removes one title at a time. MCP clients use the same three Operations: `integrations_hris_titles` (read), `integrations_map_hris_title` and `integrations_unmap_hris_title` (both `:in_app`). Nothing is reassigned when a mapping changes — the next sync applies it, and each write previews what that sync will do.

Edits are **title-centric**: `HrisConfig#map_title` moves one title out of whichever mapping held it and into the group for its `(role code, level_ordinal)`, creating it if needed; `#unmap_title` removes it and drops a group it empties. So the stored shape is unchanged and a title can never be listed twice. Mappings are tenant data, entered on the integrations page — the seed writes none.

### Mode 1 — title carries the level

Use when HRIS titles like "Senior Software Engineer" directly imply a framework level:

```ruby
HrisRoleMapping.new(
  hris_titles: ["Senior Software Engineer"],
  framework_role_code: "E",
  level_ordinal: 5
)
```

No `level_field_id` needed. The mapping's fixed `level_ordinal` wins even if the HRIS also has a level column.

### Mode 2 — level from a separate HRIS custom column

Use when the HRIS has a "Level" custom column populated with the ordinal (e.g. a HiBob custom column `work.customColumns.column_1234567890123` containing values `"1"` through `"10"`):

```ruby
# On HrisConfig:
level_field_id: "column_1234567890123"

# In role_mappings — no level_ordinal:
HrisRoleMapping.new(
  hris_titles: ["Engineering Manager", "Senior Engineering Manager"],
  framework_role_code: "EM"
)
```

The `Client` adds `work.customColumns.<level_field_id>` to the requested fields; `ResponseMapper` extracts `hris_level_ordinal` from `humanReadable.work.customColumns.<level_field_id>` (APPEND mode gives the display string, which should be the ordinal number). The adapter then uses `person.hris_level_ordinal` as the fallback when `mapping.level_ordinal` is nil.

### Mixed mode

Both modes can coexist in one tenant's mappings — some titles carry their level explicitly, others rely on the column.

### Title normalization

Titles are matched case-insensitively after `downcase.strip` — `HrisRoleMapping.normalize_title` is the one definition, and `HrisConfig#title_lookup` / `#mapping_for` the one lookup the adapter, the integrations page and the Operations share. Everything inside the title is significant: "Engineering Manager (EM3)" does **not** match a mapping for "Engineering Manager". Duplicates across mappings are rejected by `HrisConfig` validation.

### Unmapped titles

Skipped by Pass 5, and **the person keeps whatever assignment an earlier title gave them** — the sync neither moves nor unassigns them. That is how a renamed HiBob title leaves someone on the wrong ladder for weeks without anyone noticing ([#436](https://github.com/mr-yum/growth-os/issues/436): "Engineering Manager (EM3)" stayed on E3).

Three places now surface it:

- The integrations page's "Unmapped titles" card, which calls out each holder still on an assignment from an earlier title (`Integrations::HrisPersonRow#stale_assignment?`).
- `HrisSyncJob` logs `unmapped_titles`, `missing_roles`, `missing_levels` and `missing_ordinals` as a warning after every sync that had any.
- `integrations_hris_titles` over MCP.

`Integrations::HrisTitleResolution` is the one resolution of title → role and level. The adapter's Pass 5 dispatches on its rows (`Integrations::HrisPersonRow#status`), and the integrations page, the MCP tools and a mapping's preview read the same rows — so a change to the rules lands in one place, and nothing can describe a sync that does something else. It resolves assignments within the framework the sync assigns into (`FrameworkState::Framework.first`).

### The sync must not save the config it read at the start

A sync runs for a while, and a mapping can change underneath it. The adapter stamps `last_synced_at` on a freshly locked, reloaded tenant (`stamp_last_synced`) rather than saving the `config` it read up front, which would write the old mappings back. Any new write to `hris_config` from a long-running path must do the same; the mapping Operations lock the tenant row too.

## The field catalogue

`adapter.field_catalogue` returns the HRIS's fields as `Hris::Field`s, so a settings screen can offer them by name and nobody pastes a field id ([org-graph-design.md → Which HRIS field a fact comes from](../team-planning/org-graph-design.md#which-hris-field-a-fact-comes-from)). Each field has:

- **`id`**: the path the people API takes. For HiBob that is the field's `jsonPath`, such as `work.department` or `work.customColumns.column_1700000000001`. `HrisConfig#level_field_id` still holds the bare column id; a picker that writes it must strip the prefix, or the config must move to the full path.
- **`name`**: the label HiBob shows.
- **`kind`**: `:list` when the value comes from a named list and so has an id of its own (HiBob types `list`, `multi-list`, `hierarchy-list`), else `:text`. Dates, numbers and employee references are `:text`, since their values carry no id.
- **`values`**: a list field's `Hris::Field::Value`s (`id`, `name`), read from `GET /company/named-lists` by the field's `typeData.listId`. A hierarchy list is flattened, an archived value is dropped with its children, and a value with no id is dropped. The named lists are fetched only when some field is a list. A list HiBob did not return leaves the field a list with no values.

The base adapter caches the catalogue per tenant and HRIS account for an hour (`FIELD_CATALOGUE_TTL`), as plain hashes under a key that names `Hris::Field::SHAPE`, so a deploy that changes the shape never reads an old entry; providers implement only the uncached `fetch_field_catalogue`. **An HRIS failure raises** (the client's `Errors::*`, or `Errors::UnexpectedResponseError` for a body of the wrong shape) **and caches nothing**, so a caller never mistakes an outage for a tenant with no fields. HiBob documents the named lists as an array of `{ name, items }`; the adapter also reads an object keyed by list name, and a list's entries under `values` when it has no `items`, since no live response has confirmed the shape yet. A list with neither array raises. Test with `test/fixtures/files/hibob/people_fields_response.json` and `named_lists_response.json`; the test environment's null cache store means a caching test swaps in a `MemoryStore`.

## Adding a new HRIS field to the sync

To pull an additional field (e.g. employment type, cost center, location) through into `Person`:

1. **Migration** — generate a new migration (`bin/rails generate migration AddXyzToPeople xyz:string`), run `bin/rails db:migrate`.
2. **Client** — add the field to `BASE_FIELDS` in `Hris::Hibob::Client`. For custom columns, add a constructor parameter like `level_field_id` and include it via `default_fields`.
3. **ResponseMapper** — extract from the raw or humanReadable hash and add to the attrs hash returned by `#call`. Use `dig_human_readable_work` for list-type fields, `dig_work` for plain strings. A list field whose item id matters (it survives a rename, the label doesn't) also goes in `#list_values`, which pairs the id with the label from either payload shape: nested `work.<field>`, or flat `"/work/<field>" => { "value" => id }`.
4. **Tests** — add a case to `response_mapper_test.rb` with fixture data. Update `test/fixtures/files/hibob/people_search_response.json` if needed.
5. **Adapter** — no changes needed if you just want the field on Person. If the field affects assignment logic, add it to Pass 5.

## Adding a new HRIS provider

Subclass `Hris::BaseAdapter` under `app/integrations/hris/<provider>/`:

```ruby
# app/integrations/hris/bamboohr/adapter.rb
class Hris::Bamboohr::Adapter < Hris::BaseAdapter
  def provider_name = "bamboohr"

  def sync_people
    # Reuse the Pass 1-5 pattern from Hris::Hibob::Adapter
  end

  def fetch_employees
    client.list_employees
  end

  def fetch_field_catalogue
    # Map the provider's field metadata to Hris::Field, each :list or :text
  end

  private

  def client
    @client ||= Hris::Bamboohr::Client.new(
      service_user_id: tenant.hris_secrets.service_user_id,
      api_token: tenant.hris_secrets.api_token
    )
  end
end
```

Then register the provider in `HrisConfig::PROVIDERS` and add a branch in `HrisSyncJob#resolve_adapter`. A provider that needs credential fields beyond `HrisCredentials::KEYS` extends that list, the connection form and `Tenant#update_hris!` together.

Each provider has its own Client, ResponseMapper, errors, and webhook validator. Do NOT try to abstract across providers — their APIs differ too much. Share conventions, not code.

## Testing HRIS adapters

### Client tests — use Faraday test adapter

```ruby
setup do
  @stubs = Faraday::Adapter::Test::Stubs.new
  @client = Hris::Hibob::Client.new(service_user_id: "u", api_token: "t")
  stubbed = Faraday.new(url: Hris::Hibob::Client::BASE_URL) do |f|
    f.request :json
    f.response :json
    f.response :raise_error
    f.adapter :test, @stubs
    f.headers["Authorization"] = "Basic #{Base64.strict_encode64('u:t')}"
  end
  @client.instance_variable_set(:@connection, stubbed)
end

should "fetch all pages" do
  @stubs.post("/v1/people/search") { [200, {}, fixture_hash] }
  employees = @client.search_people
  @stubs.verify_stubbed_calls
end
```

Stub paths include the full `/v1/` prefix because Faraday resolves relative paths against `BASE_URL`.

### ResponseMapper tests — pure function, JSON fixtures

Load `test/fixtures/files/hibob/people_search_response.json` and assert against the returned attrs hash. No database, no mocks. Add new employees to the fixture for edge cases.

### Adapter tests — stub the client, use real DB

```ruby
setup do
  @tenant = create(:tenant, :with_hibob_config)
  ActsAsTenant.current_tenant = @tenant
  @fixture = JSON.parse(File.read(Rails.root.join("test/fixtures/files/hibob/people_search_response.json")))
end

def build_adapter(employees)
  adapter = Hris::Hibob::Adapter.new(@tenant)
  mock_client = Minitest::Mock.new
  mock_client.expect(:search_people, employees, show_inactive: true)
  adapter.instance_variable_set(:@client, mock_client)
  adapter
end
```

For Pass 5 tests, seed `FrameworkState::Framework` + `Role` + `Level` via factories in `test/factories/framework_states.rb` before running the sync. The adapter finds the framework via `FrameworkState::Framework.first` within the tenant scope.

### Factory trait

`test/factories/tenants.rb` has a `:with_hibob_config` trait that seeds sample `role_mappings` and `level_field_id`. Extend it when adding new mapping fields:

```ruby
trait :with_hibob_config do
  hris_config do
    HrisConfig.new(
      provider: "hibob",
      sync_enabled: true,
      level_field_id: "column_test_id",
      role_mappings: [
        HrisRoleMapping.new(hris_titles: ["Software Engineer"], framework_role_code: "E"),
        HrisRoleMapping.new(hris_titles: ["Engineering Manager"], framework_role_code: "EM")
      ]
    )
  end
  hris_credentials { { "service_user_id" => "u", "api_token" => "t" } }
end
```

## Dev seeding

`db/seeds.rb` seeds the Null Island demo tenant with synthetic people and no HRIS connection. To exercise a real HiBob sync in development, enter the credentials and mappings on `/tenant/integrations/hris` (they live encrypted on the tenant) and press Sync now — the framework must exist first, or Pass 5 silently skips.

## Anti-patterns

```ruby
# Bad — global credentials
class Hris::Hibob::Client
  @@service_user_id = ENV["HIBOB_USER"]
end

# Bad — hardcoded custom column
DEFAULT_FIELDS = [..., "work.customColumns.column_0000000000000"]

# Bad — nested module style
module Integrations
  module Hris
    class BaseAdapter; end
  end
end

# Bad — dispatching PersonDevelopment commands without tenant metadata
command_handler.assign_to_framework(person_id, fw_id, role_id, level_id)
# projection fails: no tenant_id in event metadata

# Good — wrap in with_metadata
Rails.configuration.event_store.with_metadata(tenant_id: tenant.id) do
  command_handler.assign_to_framework(person_id, fw_id, role_id, level_id)
end

# Bad — re-calling assign_to_framework on an already-assigned person
adapter.assign_to_framework(person_id, fw_id, role_id, level_id)
# raises "Person already assigned to this framework"

# Good — check the projection and dispatch the right command
case existing_assignment
when nil           then command_handler.assign_to_framework(...)
when same_role_and_level then skip
when different_role      then command_handler.change_person_role(...)
else                          command_handler.change_person_level(...)
end
```
