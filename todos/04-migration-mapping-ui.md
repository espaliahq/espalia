# Migration Mapping UI

## Context

ADR-17 makes migration mappings mandatory at publish: `publish_version` raises if any capability archived during the current draft lacks a `MigrationMappingDefined` entry. Today, `define_migration_mapping` is command-only — there is no UI for an admin to declare "capability X is being archived; its ratings map to capability Y" or "capability X is being split into Y and Z".

Without a UI, every time an admin archives a capability in a draft they must drop into `bin/rails runner` or write a one-off script to emit the mapping event before they can publish. This makes the publish-time enforcement feel hostile rather than helpful.

## What needs to change

### Controller

`app/controllers/frameworks/migration_mappings_controller.rb`:

- `GET /frameworks/:framework_id/migration_mappings` — list pending archives needing mappings (derive from draft state)
- `POST /frameworks/:framework_id/migration_mappings` — dispatch `define_migration_mapping`
- `GET /frameworks/:framework_id/migration_mappings/:mapping_id` — show a mapping
- `DELETE /frameworks/:framework_id/migration_mappings/:mapping_id` — retract a mapping (requires new `retract_migration_mapping` command)

### Views

Phlex views under `app/views/frameworks/migration_mappings/`:

- `IndexView` — list of archived capabilities awaiting mappings (read from aggregate state via `@archives_needing_mapping`)
- `NewView` — form to define a mapping:
  - `mapping_type`: radio group (`same`, `evolved`, `split`, `archived`, `new`)
  - `to_stable_id`: select from capabilities in the draft (or "none" for `archived` type)
  - `requires_reassessment`: checkbox
  - `reason`: text

### Aggregate

Expose the pending-mapping set for read:

```ruby
# app/contexts/frameworks/aggregate.rb
attr_reader :archives_needing_mapping  # already declared
```

Or add a query method that returns enriched data (capability name, category, etc.) for display.

### Publish gate integration

When the publish button is clicked in the draft UI ([`todos/05-draft-preview-ui.md`](05-draft-preview-ui.md)), the UI should disable the button until `@archives_needing_mapping.empty?` and show a link to the mapping UI for pending archives. This gives the admin a clear next action rather than a mysterious publish failure.

### Tests

- Controller tests including denied-access and publish-blocked paths
- System test: archive a capability → publish fails → define mapping via UI → publish succeeds

## Dependencies

- [`todos/05-draft-preview-ui.md`](05-draft-preview-ui.md) — the publish button lives in the draft UI
- Requires the publish-time enforcement from this plan's ADR-17 to already be in place

## Verification

```bash
bin/rails test test/controllers/frameworks/migration_mappings_controller_test.rb
bin/rails test test/system/migration_mappings_system_test.rb
bin/rails development:precommit
```

## Out of scope

- Automatic mapping derivation (e.g. "this capability's stable_id matches 98% of a new one; default to `same`") — manual only for now.
- Cross-stream rating migration — covered by [`todos/09-framework-version-migrated-cross-stream.md`](09-framework-version-migrated-cross-stream.md).
