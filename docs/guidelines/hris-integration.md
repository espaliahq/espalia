# HRIS Integration Standards

> How to work with HRIS adapters, configure role/level mappings per tenant, add new providers, and test the sync.
> For the architecture background, see [docs/architecture/integrations.md](../architecture/integrations.md).

## File structure

```
app/
  integrations/
    hris/
      base_adapter.rb                  # Abstract interface (Hris::BaseAdapter)
      hibob/
        client.rb                      # Hris::Hibob::Client — Faraday HTTP
        adapter.rb                     # Hris::Hibob::Adapter — 5-pass sync
        response_mapper.rb             # Hris::Hibob::ResponseMapper — pure mapping
        errors.rb                      # Hris::Hibob::Errors::{AuthenticationError,RateLimitError,ApiError}
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

- **No global state.** Every `Client` instance takes `service_user_id`, `api_token`, and optional `level_field_id` in the constructor. Adapters read `tenant.hris_credentials` per sync. Never use class-level config.
- **Namespace style.** Use `class Hris::Hibob::X` not nested modules (per [rails-controllers.md](rails-controllers.md) style). The `app/integrations/` directory is a Zeitwerk root — files map to `Hris::*` directly (no `Integrations::` prefix).
- **Errors namespaced under `Errors` module.** Zeitwerk expects one constant per file; the errors module holds all error classes in a single `errors.rb`: `Hris::Hibob::Errors::AuthenticationError`.
- **Tenant metadata on RES commands.** When dispatching PersonDevelopment commands (assign/change role/change level) from an adapter, wrap the loop in `Rails.configuration.event_store.with_metadata(tenant_id: tenant.id)`. The projection reads this to set `ActsAsTenant` context.
- **Record the reporting manager.** Pass 5 also dispatches `record_reporting_manager(person_id, framework_id, person.manager_id, source: "hris")` for every touched person that has an assignment — independent of the title-mapping outcome, so a re-managed-but-unmapped person stays fresh. Like every other PersonDevelopment command above, it runs **inside the same `with_metadata(tenant_id: tenant.id)` block** (the Pass 5 loop is already wrapped) so the projection gets tenant context. Idempotent (no-op when unchanged or manager nil). This is the authoritative source for manager-rating authority (`RecordedReportingManager`); seed existing streams once via `bin/rails events:backfill_reporting_managers`. See [docs/guidelines/authorization.md](authorization.md#assessment-permissions).

## Configuring role/level mappings

`Tenant.hris_config.role_mappings` is an array of `HrisRoleMapping` StoreModel entries. Seed these in `db/seeds.rb` per tenant or add admin UI later.

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

Use when the HRIS has a "Level" custom column populated with the ordinal (e.g. me&u's HiBob `work.customColumns.column_0000000000000` containing values `"1"` through `"10"`):

```ruby
# On HrisConfig:
level_field_id: "column_0000000000000"

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

Titles are matched case-insensitively after `downcase.strip`. Whitespace inside the title is preserved ("Example Product Director Title" must match exactly on the non-space characters). Duplicates across mappings are rejected by `HrisConfig` validation.

### Unmapped titles

Silently skipped. Each unmapped title is added to `result[:unmapped_titles]` (a `Set`) for admin visibility. This is the primary feedback loop for refining the mapping — print the set from dev seeds or log from production syncs.

## Adding a new HRIS field to the sync

To pull an additional field (e.g. employment type, cost center, location) through into `Person`:

1. **Migration** — generate a new migration (`bin/rails generate migration AddXyzToPeople xyz:string`), run `bin/rails db:migrate`.
2. **Client** — add the field to `BASE_FIELDS` in `Hris::Hibob::Client`. For custom columns, add a constructor parameter like `level_field_id` and include it via `default_fields`.
3. **ResponseMapper** — extract from the raw or humanReadable hash and add to the attrs hash returned by `#call`. Use `dig_human_readable_work` for list-type fields, `dig_work` for plain strings.
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

  private

  def client
    @client ||= Hris::Bamboohr::Client.new(
      api_key: tenant.hris_credentials["api_key"],
      subdomain: tenant.hris_credentials["subdomain"]
    )
  end
end
```

Then register the provider in `HrisConfig::PROVIDERS` and add a branch in `HrisSyncJob#resolve_adapter`.

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

`db/seeds.rb` seeds the framework **before** configuring the HRIS integration, then runs an initial sync synchronously in `Rails.env.development?`. This order matters — Pass 5 needs the framework to exist or it silently skips.

The seed reads credentials from `Rails.application.credentials.dig(:hris, :hibob, :<tenant_slug>)` so real HiBob API calls can happen in dev without hardcoding secrets.

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
