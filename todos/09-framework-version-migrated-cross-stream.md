# FrameworkVersionMigrated Cross-Stream Event

## Context

When a framework publishes v(N+1), in-flight assessment cycles that pinned their `framework_version` at define time are still operating against vN. Their ratings reference `(capability_stable_id, level_ordinal)` pairs from vN's shape, and those pairs may be semantically different in v(N+1) — or may have been archived entirely.

The architecture documents a `FrameworkVersionMigrated` cross-stream event that would:

1. Fire from an async handler when `FrameworkVersionPublished` lands
2. Write an event into each affected person development stream saying "this person is now assessed against v(N+1), per the following migration mapping"
3. The person development aggregate consumes the mapping to decide what happens to each rating:
   - `same` → rating carries forward unchanged
   - `evolved` → rating carries forward, reassessment flag set
   - `split` → rating blanked, previous value attached as context, reassessment required
   - `archived` → rating surfaces for relink-or-dismiss, can't complete alignment until resolved
   - `new` → no prior rating, blank

None of this is implemented. ADR-17 (this plan) enforces that migration mappings exist at publish time; this follow-up is what actually uses them.

## What needs to change

### New event

`app/contexts/person_development/events/framework_version_migrated.rb`:

```ruby
# data: { person_id, framework_id, from_version, to_version, mappings: [...] }
# mappings: array of { from_stable_id, to_stable_id, mapping_type, requires_reassessment }
```

### Async handler

`app/contexts/person_development/async_handlers/framework_version_migrator.rb`:

```ruby
class PersonDevelopment::AsyncHandlers::FrameworkVersionMigrator < ApplicationJob
  prepend RailsEventStore::AsyncHandler

  def perform(event)
    # Only react to FrameworkVersionPublished
    return unless event.is_a?(Frameworks::Events::FrameworkVersionPublished)

    ActsAsTenant.with_tenant(Tenant.find(event.metadata[:tenant_id])) do
      framework_id = event.data[:framework_id]
      new_version = event.data[:version]

      # Find all person development streams pinned to the previous version
      AssessmentCycle.where(framework_id: framework_id, framework_version: new_version - 1).each do |cycle|
        migrate_cycle(cycle, new_version)
      end
    end
  end

  private

  def migrate_cycle(cycle, new_version)
    # Read migration mappings defined between versions
    mappings = FrameworkState::MigrationMapping.where(framework_id: cycle.framework_id, published_version: new_version).to_a

    cycle.participants.each do |participant|
      person_development_handler.migrate_framework_version(
        participant.person_id, cycle.framework_id, cycle.framework_version, new_version, mappings
      )
    end
  end
end
```

### PersonDevelopment aggregate command

`PersonDevelopment::Aggregate#migrate_framework_version` applies the event into the person's stream and mutates in-memory state:

- For each existing rating, check the mapping for its `capability_stable_id`
- Apply the mapping rule (carry, blank, relink, etc.)
- Emit `RatingArchived` / `RatingRelinked` / `ReassessmentRequired` events as needed
- Update the cycle's `framework_version` pointer if the cycle should roll forward

### Assessment cycle integration

[`AssessmentCycle`](../app/read_models/assessment_cycle.rb) read model's `framework_version` needs to update when migration completes. Or: cycles explicitly opt in to migration on publish (tracked by a new `migrate_on_publish` flag per cycle).

Design decisions:

- Auto-migrate all in-flight cycles or require explicit opt-in? Default to explicit opt-in; add an admin "migrate all" command for bulk rollover.
- What about cycles that are already at a later stage (e.g. FullAlignmentCompleted)? Don't migrate — they're frozen snapshots.

### Tests

- Unit tests for the async handler per mapping type
- Integration test: publish v2 → in-flight cycle receives migration event → ratings carry / blank / relink correctly per mapping
- Test that completed alignments are not migrated

## Dependencies

- ADR-17 (this plan) — migration mappings must exist at publish
- [`todos/04-migration-mapping-ui.md`](04-migration-mapping-ui.md) — UI to author mappings
- Read model: `FrameworkState::MigrationMapping` already exists (verify)

## Verification

```bash
bin/rails test test/contexts/person_development/async_handlers/framework_version_migrator_test.rb
bin/rails test test/contexts/assessment_cycles/
bin/rails development:precommit
```

End-to-end: define a cycle against v1, rate some capabilities, publish v2 with an archived capability, observe the in-flight cycle receive a FrameworkVersionMigrated event that surfaces the archived capability for relink/dismiss.

## Out of scope

- UI for relink/dismiss of archived capabilities in an active assessment — separate follow-up.
- Retroactive migration for cycles that pre-date this mechanism — manual for now.
