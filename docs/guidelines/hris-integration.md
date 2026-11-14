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
        adapter.rb                     # Hris::Hibob::Adapter — the passes of a sync
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
- **Offboard on deactivation (Pass 3b).** An inactive person must hold no live participation: after Pass 3, the adapter withdraws every inactive person from any open cycle (`unenroll` reason `left_company` — a person-scoped removal, never `cycle_closed`, which is reserved for cycle conclusion) and removes their framework assignments. The sweep is state-driven and idempotent (it self-heals stragglers regardless of how the person became inactive), and Pass 5 skips inactive people. Reactivation needs no special handling — a returnee flows through the normal new-hire path (Pass 1 re-activates, Pass 5 re-assigns, auto-enroll picks them up). A tenant fed from the Org Graph runs it for Espalia-held people only (see story 9.1 below). **New providers must implement the same offboarding sweep.**
- **Record people and write Org Graph differences (Pass 2b).** After managers resolve, the adapter hands each touched person's title, HiBob level label (only with a level column), manager, site, FTE (`payroll.employment.fte`, a percentage, stored as a fraction), employment type (`payroll.employment.type`, HiBob's own label), start date, termination date (`internal.terminationDate`) and employment status to `OrgGraph::CommandHandler#sync_person`, inside `with_hris_event_context`. One load per person. A person the Org Graph has not seen gets `PersonRecorded` with those facts, an inactive one as `left`; after that a change in status writes `PersonLeft` or `PersonReturned`, and each differing fact writes its event, provider `hibob`, effective today. A leaver's facts are not compared. A join is effective on the start date and a leaving on the termination date; someone HiBob shows active before their start date stays `pending`. `ResponseMapper#org_graph_facts` reports a fact only when HiBob sends its field: HiBob silently drops a field the service user can't read, and that fact is then never compared, while a field sent blank is recorded as absent. Each command is refused unless `hibob` holds the fact, as the structure stream's `FactProviderSet` events have it (never `org_fact_providers`, which a Structure rebuild empties), and the person carries a `hibob` external id; connecting the HRIS and predeploy's `org_graph:claim_hris_facts` hand it `OrgGraph::StructureAggregate::HRIS_FACTS`, and a refused person lands in the result's `errors` without stopping the run. A fact the sync starts writing joins that list in the same change. Country is always absent until the field mapping (6.4). Rolling it out to an existing tenant: [org-graph-first-sync.md](../runbooks/org-graph-first-sync.md). The manager comes from the row's `reportsTo`, so an explicit null records a lost manager, while a withheld or unreadable `reportsTo` (`ResponseMapper#manager_supplied?`) or a manager Espalia does not know is left uncompared. Person Development is untouched unless the tenant is fed (story 9.1 below). Cost centre joins with the field mapping (6.4). See [org-graph-design.md](../team-planning/org-graph-design.md#how-the-sync-writes). **New providers must do the same.**
- **Leave people the response no longer holds (Pass 2c).** Every HiBob person whose `external_id` is missing from the response goes to `OrgGraph::CommandHandler#record_absence`, inside `with_hris_event_context`: `PersonLeft`, provider `hibob`, effective on the first sync that misses them. Someone already left, or never recorded, gets nothing, so later syncs write nothing. A failed page, or one without an `employees` list, raises in `Client#search_people` before any pass runs. A returner matches by `external_id`, so they keep their Person and stream, and Pass 2b writes `PersonReturned`. A write that fails is reported in the result's errors and does not hold up Pass 3, so a leaver is still offboarded on time (before cut-over; after it, offboarding waits one sync, see story 1.4 below); the next sync, still missing them, writes the `PersonLeft`, dated that day. The pass loads one stream per absent HiBob person on every sync. **New providers must do the same.**
- **Brake on mass absence (Passes 2c and 3).** Both passes read one absent set, `Hris::BaseAdapter#absent_people`, so `Person.status` and the Org Graph agree on who left. It is empty when the response is empty (a failed sync), or when the active people missing from it are more than both numbers in `ABSENCE_BRAKE`: 10% of the provider's active people, and 5 people. A partial response, such as a service user who lost sight of a department, looks exactly like a mass leaving, and a `PersonLeft` stays in history. Either refusal adds one error to the result that names nobody; a tripped brake also logs a warning with the counts. The next sync decides afresh, so a lasting partial response, or a real mass leaving, trips it on every sync until someone acts. There is no override yet. **New providers must call it too.**
- **Never write a forgotten person back (story 8.2).** A row `OrgGraph::Forgetting` erased keeps only `forgotten_external_id_digest`, an HMAC of `tenant:source:external_id`. Pass 1 computes the digest for any id no live row holds. A match HiBob shows as not employed, or employed but not yet started, is skipped and counted in the result's `forgotten_skipped`, naming nobody. A match back at work gets a new Person with a new id, and the digest moves off the old row in the same transaction, so the two are never linked. If any row holds a digest and the key is missing, the sync raises `OrgGraph::Forgetting::KeyMissing` before writing anything. The forgetting run also calls the adapter's `active_external_ids` to spare anyone the HRIS still holds. Operating it: [org-graph-forgetting.md](../runbooks/org-graph-forgetting.md). **New providers must do the same.**
- **Leave the projected columns alone once cut over (story 1.4).** For a tenant with `org_graph_people_projected_at` set, Pass 1 writes neither `job_title` nor `status`, Pass 2 sets no manager, and Pass 3 marks no one inactive: Pass 2c's `PersonLeft` does it through the projection, and Pass 3 records anyone never recorded as having left, dated by the same evidence a cut-over reads (`OrgGraph::PeopleCutover.leaving`): the termination date their stored HiBob record holds, when it falls on or before the sync's day and not before the record's start date, else the sync's day, with the source in `left_on_source`. Their row was active, so its last update is no evidence. Nothing works around a failed Pass 2c write: the person stays active, the error is reported, and the next sync writes the `PersonLeft`, so offboarding waits one sync. Pass 2b's events write all three through `OrgGraph::Projections::PeopleColumns`, so Pass 2b reads HiBob's status from the response, never from the row. A new person's row still starts with HiBob's title and status. The whole sync runs inside `OrgGraph::PeopleCutover.hold_off(tenant)`, since it reads the flag once and a cut-over must not land mid-sync. Cutting a tenant over, and back: [org-graph-people-cutover.md](../runbooks/org-graph-people-cutover.md). **New providers must do the same.**
- **Feed Person Development from the Org Graph once fed (story 9.1).** For a tenant with `person_development_fed_at` set (always after its people are cut over), Pass 3b offboards only Espalia-held people, and Pass 5 dispatches nothing, though it still tallies unmapped titles and missing roles and levels. `OrgGraph::SyncHandlers::PersonDevelopmentFeed` follows each `PersonRecorded`, `TitleChanged`, `LevelChanged`, `ManagerChanged`, `PersonLeft` and `PersonReturned` instead, and `OrgGraph::PersonDevelopmentFeed#reconcile` reads the person's Org Graph stream and Person Development stream and issues only the difference: assign, one role change (title and level together), a level change, a withdrawal then unassignment for a leaver, a reassignment for a returner, and the reporting manager. It resolves through `Integrations::HrisTitleResolution#target`, so it maps titles exactly as Pass 5 did. Only HRIS-held people are fed, a forgotten person gets nothing, and an unmapped title keeps the current assignment. A manager is cleared only when the HRIS said there is none (`PersonAggregate#fact_supplier`); a fact a person was recorded without, or a withheld field, clears nothing. A person recorded with no manager therefore keeps a manager Person Development already held until the HRIS names a new one; the cut-over's dry run cannot count them. Each reconcile runs in a savepoint, so a refusal is logged and counted under `errors` without failing the sync. The result's `person_development` counts what the handler did, and `HrisSyncJob` then enqueues `OrgGraph::PersonDevelopmentSweepJob`, which reconciles every HRIS-held person, one short transaction each, so a mapping edited between syncs lands too. A reconcile plans from the assignments, enrollments and published framework, so it raises `ProjectionVersion::Rebuilding` while any of their projections (`PersonDevelopmentFeed::PLANNED_FROM`) is rebuilt; the sweep counts those under `skipped_while_rebuilding`. During a structure rebuild Pass 3b still offboards the HRIS-held leavers it held back, since no `PersonLeft` reached the Org Graph for the feed. The flag is read inside `hold_off`, like the people cut-over's. Feeding a tenant, and back: [org-graph-person-development-cutover.md](../runbooks/org-graph-person-development-cutover.md). **New providers get this for free once they write the Org Graph.**
- **Record the reporting manager.** Pass 5 also dispatches `record_reporting_manager(person_id, framework_id, person.manager_id, source: "hris")` for every touched person that has an assignment — independent of the title-mapping outcome, so a re-managed-but-unmapped person stays fresh. Like every other PersonDevelopment command above, it runs **inside the same `with_metadata(tenant_id: tenant.id)` block** (the Pass 5 loop is already wrapped) so the projection gets tenant context. Idempotent (no-op when unchanged or manager nil). A fed tenant skips it, as the feed records and clears the manager instead. This is the authoritative source for manager-rating authority (`RecordedReportingManager`); seed existing streams once via `bin/rails events:backfill_reporting_managers`. See [docs/guidelines/authorization.md](authorization.md#assessment-permissions).

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

Use when the HRIS has a "Level" field populated with the ordinal (e.g. a HiBob custom column `work.customColumns.column_1234567890123` containing values `"1"` through `"10"`):

```ruby
# On HrisConfig, the catalogue id the picker saves:
level_field_id: "work.customColumns.column_1234567890123"

# In role_mappings — no level_ordinal:
HrisRoleMapping.new(
  hris_titles: ["Engineering Manager", "Senior Engineering Manager"],
  framework_role_code: "EM"
)
```

The `Client` adds the level field to the requested fields; `ResponseMapper` extracts `hris_level_ordinal` from the same path under `humanReadable` (APPEND mode gives the display string, which should be the ordinal number). The adapter then uses `person.hris_level_ordinal` as the fallback when `mapping.level_ordinal` is nil.

**The admin chooses the level field by name** on the connection form ([#67](https://github.com/espaliahq/espalia/issues/67)). `Views::Integrations::HrisLevelFieldFrame` is a lazy frame inside that form, loaded from `Tenant::HrisLevelFieldsController#show`, which reads `field_catalogue` and offers each field by name, marked list or text, with None first. The page never waits on the HRIS. Until the frame loads, and whenever the HRIS can't be read or no credentials are stored, it carries the current value in a hidden field and says why, so saving the connection keeps it. A stored field the catalogue no longer lists stays selected, marked "no longer in the HRIS". The frame is web-only like the rest of the connection form.

**One stored form: the catalogue id**, the field's full path. A level field saved before [#67](https://github.com/espaliahq/espalia/issues/67) was a bare custom-column id (`column_…`); the `StoreHrisLevelFieldAsCatalogueId` migration gives it the `work.customColumns.` prefix. `Hris::Hibob::Client.field_path` reads either form (only a `column_…` id gains the prefix), and the client, the mapper and the picker all go through it, so the sync requests and reads the same field whether the migration or the code lands first. The mapper reads a `root.*` field at the top of `humanReadable`, where HiBob puts it. A form whose picker failed to render posts no level field, and the connection keeps the stored one.

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

- **`id`**: the path the people API takes. For HiBob that is the field's `jsonPath`, such as `work.department` or `work.customColumns.column_1700000000001`. `HrisConfig#level_field_id` holds this id too (see Mode 2).
- **`name`**: the label HiBob shows.
- **`kind`**: `:list` when the value comes from a named list and so has an id of its own (HiBob types `list`, `multi-list`, `hierarchy-list`), else `:text`. Dates, numbers and employee references are `:text`, since their values carry no id.
- **`values`**: a list field's `Hris::Field::Value`s (`id`, `name`), read from `GET /company/named-lists` by the field's `typeData.listId`. A hierarchy list is flattened, an archived value is dropped with its children, and a value with no id is dropped. The named lists are fetched only when some field is a list. A list HiBob did not return leaves the field a list with no values.

The base adapter caches the catalogue per tenant and HRIS account for an hour (`FIELD_CATALOGUE_TTL`), as plain hashes under a key that names `Hris::Field::SHAPE`, so a deploy that changes the shape never reads an old entry; providers implement only the uncached `fetch_field_catalogue`. **An HRIS failure raises** (the client's `Errors::*`, or `Errors::UnexpectedResponseError` for a body of the wrong shape) **and caches nothing**, so a caller never mistakes an outage for a tenant with no fields. HiBob documents the named lists as an array of `{ name, items }`; the adapter also reads an object keyed by list name, and a list's entries under `values` when it has no `items`, since no live response has confirmed the shape yet. A list with neither array raises. Test with `test/fixtures/files/hibob/people_fields_response.json` and `named_lists_response.json`; the test environment's null cache store means a caching test swaps in a `MemoryStore`.

## Previewing a field

Before an admin chooses the field a level or a fact comes from, `Integrations::HrisFieldPreview` shows what it would give ([#107](https://github.com/espaliahq/espalia/issues/107)). For a level: the units it would make, with their labels and head counts. For a fact (`cost_centre`, `country`): who has a value and who would change from what the Org Graph holds. Both count the people the field is blank for and those whose record withholds it.

- **It writes nothing.** `adapter.read_field(field_id, kind:, alongside:)` asks the HRIS for that one field beside each current person's id, live and uncached, since `hris_raw_data` holds only the fields the last sync asked for.
- **One reader with the mirror.** Each record goes through `ResponseMapper#field_value`, which gives a `Hris::FieldValue`: `:value` with a list item's id and label (or a text field's text), `:blank` for a field sent empty, `:withheld` for a record that leaves it out, `:unreadable` for a value in a shape Espalia does not know, list or text (a hash or an array, or a flat wrapper with no `"value"`), and for a country whose site is unreadable. Unreadable says nothing, as withheld does: it never ends a membership, and the sync writes no site, country or cost centre for it, so the preview's unreadable count is exactly the people the sync skips. A site and country travel together, so either one unreadable skips both. The preview counts it on its own. Units are told apart by `#key`, the list id before the label, so two items sharing a label stay two units, as the mirror (6.7) makes them.
- **Only the people the sync writes for**: active, from that HRIS, with a row in Espalia. A withheld or unreadable person is never compared.
- **A pair waits for both halves here too.** The sync writes a country only beside a site, so the query passes `alongside: "site"` for `country` and the adapter reads anyone whose record withholds `work.site` as withheld.
- **"Would change" reads the person's stream** (`OrgGraph::PersonAggregate#fact`), because `org_fact_ages` keeps only facts Espalia provides. That is one stream read per person, fine for a preview an admin asks for.
- MCP clients call `integrations_hris_field_preview`, which returns counts and unit labels, never who is in a unit. A label is the field's own value, so a field that names people names them. A refused credential or a rate limit comes back as a parameter error with the same sentence the web shows.
- On the web, `Tenant::HrisFieldPreviewsController` renders `Views::Integrations::HrisFieldPreviewFrame` at `/tenant/integrations/hris/field_preview?field_id=…&target=…`, the panel the Org Graph settings screen loads in an eager frame for each fact and each empty level ([#126](https://github.com/espaliahq/espalia/issues/126)). `frame_id:` and `heading_level:` let each caller give it its own id and fit it under its own heading. A plain visit wraps it in a page of its own. Each HRIS error becomes a sentence in the frame, as the level field picker does; anything the Operation does not name is reported and shown as "did not answer".

## Adding a new HRIS field to the sync

To pull an additional field (e.g. employment type, cost center, location) through into `Person`:

1. **Migration** — generate a new migration (`bin/rails generate migration AddXyzToPeople xyz:string`), run `bin/rails db:migrate`.
2. **Client** — add the field to `BASE_FIELDS` in `Hris::Hibob::Client`. For custom columns, add a constructor parameter like `level_field_id` and include it via `default_fields`.
3. **ResponseMapper** — extract from the raw or humanReadable hash and add to the attrs hash returned by `#call`. Use `dig_human_readable_work` for list-type fields, `dig_work` for plain strings. A list field whose item id matters (it survives a rename, the label doesn't) also goes in `#list_values`, which pairs the id with the label from either payload shape: nested `work.<field>`, or flat `"/work/<field>" => { "value" => id }`.
4. **Tests** — add a case to `response_mapper_test.rb` with fixture data. Update `test/fixtures/files/hibob/people_search_response.json` if needed.
5. **Adapter** — no changes needed if you just want the field on Person. If the field affects assignment logic, add it to Pass 5.

### A field the tenant's mapping names

An Org Graph fact can be read from a field each tenant chooses. The choice lives beside the fact's provider: `FactProviderSet` carries `fields`, the HRIS path for each part of the fact, and `OrgFactProvider.fields_for(provider)` reads them back. Setting a field always sets its provider in the same event, so a fact Espalia holds never has one. Moving the fact to another provider clears its fields.

The HiBob adapter passes `fields_for("hibob")` to the client, which requests each path beside `BASE_FIELDS`, and to `ResponseMapper#org_graph_facts`, which reads each part from its path. Only the parts in `OrgGraph::StructureAggregate::MAPPABLE_FIELDS` can be mapped: `cost_centre`, and a site's `country`. To make another part mappable, add it there and read it in `#org_graph_facts`. Keep the rule that a fact is reported only when HiBob sends its field, and that a pair waits for both halves.

Take each path from the catalogue (`#field_catalogue`), never typed, so the search names only fields HiBob knows.

### A structure level read from a field

A level the HRIS provides can name its field: `LevelProviderSet` carries `field`, projected as `OrgTaxonomyLevel#provider_field`. `Hris::LevelMirror.levels(provider)` lists those levels, the client requests each field, and after the people are recorded the adapter hands `Hris::LevelMirror` the catalogue and each current person's `ResponseMapper`. The mirror reads a person's value through `ResponseMapper#field_value`, which tells a value, a blank and a withheld field apart; keep that distinction in any new provider's mapper, since a withheld field must change nothing. Units are referenced as `"<field path>/<value id or text>"`. The rules are in [org-graph-design.md → How a sync mirrors a level](../team-planning/org-graph-design.md#how-a-sync-mirrors-a-level-67). The mirror is provider-agnostic: a new adapter calls it the same way. The mirror plans from the units and members Espalia holds, so it raises `ProjectionVersion::Rebuilding` while either projection is rebuilt. The adapter rescues it, writes no unit or membership, and adds the levels to the result's `levels_skipped_while_rebuilding`, kept apart from `errors` so a deploy that rebuilds raises no alert. Every Org Graph write also checks who provides a fact (`OrgFactProvider`), and the mirror reads its levels, from `org_graph/structure`'s tables, so the sync holds that projection's guard from before it reads the levels to the end (`#unless_structure_rebuilding`). A sync that starts during a structure rebuild still runs Passes 1, 3 (before cut-over), 3b, 4 and 5, writes nothing to the Org Graph, and counts the people it skipped in `people_skipped_while_rebuilding`. For a cut-over tenant a leaver's row still reads active until the next sync writes `PersonLeft`, so Pass 3b offboards anyone HiBob reported inactive and Pass 5 skips them. A new adapter must do the same; see [projection-rebuild.md → Writes that refuse during a rebuild](../runbooks/projection-rebuild.md#writes-that-refuse-during-a-rebuild).

### Handing a level over

A level Espalia holds moves to a field through `Hris::LevelHandover` (6.8): `#compare` reads the field live and sets it against the level's units, `#hand_over!` switches it as one cause in one transaction, and `#hand_back!` returns it. Each unit's value is suggested by name and confirmed by an admin; every unit left over must be succeeded or retired first, and a value can match only one unit. A leftover unit that can't retire today, because it has live sub-units or a change dated later, blocks the switch until someone moves them. A member whose list item the HRIS no longer offers reads as withheld, as the mirror reads it, and keeps Espalia's membership. Handing back also forgets the parents the mirror was reading for the level's units. The switch runs the mirror with `cause_id:` and `brake: false`, because the admin has already confirmed what it ends: over the brake, the operation needs the comparison's two counts. Both switches carry the comparison's fingerprint and are `:in_app` over MCP. The rules are in [org-graph-design.md → Handing a level over, and back](../team-planning/org-graph-design.md#handing-a-level-over-and-back-68).

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

Then register the provider in `HrisConfig::PROVIDERS` and add a branch in `Hris::BaseAdapter.for`, which the sync job and the level field picker both use. A provider that needs credential fields beyond `HrisCredentials::KEYS` extends that list, the connection form and `Tenant#update_hris!` together.

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

**No test reaches the live HiBob API.** `test/support/offline_hibob.rb` makes an unstubbed client raise the error an unreachable HRIS gives, so a system test that opens the HRIS page shows the level field frame's "did not answer" state. To show the picker, stub `Hris::BaseAdapter.for` with an object that answers `field_catalogue`, and keep the stub active until the frame is `[complete]` (`test/system/hris_level_field_system_test.rb`).

For Pass 5 tests, seed `FrameworkState::Framework` + `Role` + `Level` via factories in `test/factories/framework_states.rb` before running the sync. The adapter finds the framework via `FrameworkState::Framework.first` within the tenant scope.

### Factory trait

`test/factories/tenants.rb` has a `:with_hibob_config` trait that seeds sample `role_mappings` and `level_field_id`. Extend it when adding new mapping fields:

```ruby
trait :with_hibob_config do
  hris_config do
    HrisConfig.new(
      provider: "hibob",
      sync_enabled: true,
      level_field_id: "work.customColumns.column_test_id",
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
