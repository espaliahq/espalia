# Shreddable event fields — design

> Status: partly built. The plan key store, the declaration and the guard are built;
> [What is built](#what-is-built) says what they do. Plan and scenario names and scenario
> descriptions are shreddable under the plan's key, as are plan-held values. A note on a
> change seals under its subject's key: a person's for a change about a person, the plan's
> otherwise. [The index](README.md) lists the companion designs, the mockups and the plan.

Events are immutable. Some of what they should hold must be forgettable: a salary pasted
into a plan, a note about why someone is moving, a reason for a change in hours. A
shreddable field is encrypted under a key that can be deleted. Delete the key and the
value is unreadable in the event store, while the event and the rest of its data remain.

This is a platform facility. [Team Planning](team-planning-design.md) needs it
from its first version. [The Org Graph](org-graph-design.md)
does not need it to start, and needs it before it holds anything sensitive. Evidence,
comments and feedback elsewhere in Espalia are free text about a person and would
benefit from it.

## Four kinds of event field

| Kind | Example | Stored |
|---|---|---|
| Reference | `person_id`, `manager_id` | In clear. An opaque id. |
| Clear | A level, a team, an FTE | In clear. |
| Shreddable by person | A reason for leaving, pay held by the Org Graph | Encrypted under that person's key. |
| Shreddable by plan | A note on a unit change, a scenario description, a budget amount | Encrypted under that plan's key. |
| Shreddable by person within a plan | Their uploaded pay, a corrected level, a planned promotion, a note on a change to them | Encrypted under that person's key in that plan. |

A field has exactly one key. Data a plan holds about a person is under that person's key
in the plan. It goes when the plan goes, as every key in the plan does. It also goes
when the person is forgotten, which destroys their key in every plan at once and leaves
the rest of each plan readable.

## Mechanism

RailsEventStore provides an encryption mapper. An event class declares which fields are
encrypted and how to find the key:

```ruby
class TeamPlanning::Events::PlanDataSet < RubyEventStore::Event
  def self.encryption_schema
    { value: ->(data) { "plan-#{data.fetch(:plan_id)}" } }
  end
end
```

The mapper encrypts on write and decrypts on read. When the key is gone, the field reads
back as a forgotten-data placeholder.

We use the library's key repository interface and its `EncryptionKey`, but not its
mapper. Its schema sees only the event's data, and the tenant is in the metadata; it
stores raw bytes, and our event store is JSON; and it hands back the plain value, where
we want a wrapper. [What is built](#what-is-built) has our own.

We supply:

- **A key store in the application database**, one key per person and one per plan,
  namespaced by tenant. The library's own store is in-memory.
- **A declaration** that reads better than the raw schema, for example
  `shreddable :value, by: :plan`.
- **The guard** described below.

## What is built

**A scenario's description is sealed in `TeamPlanning::Events::ScenarioDescribed`** and
in the scenarios read model's `description` column. The plan aggregate never sees the text
it wrote, so `Operations::TeamPlanning::DescribeScenario` reads what the scenario holds
from that row, by id, under the plan's lock, and the aggregate writes nothing for the same
text. While a rebuild holds the read model the operation writes rather than guess.

**An archived plan's pricing inputs are sealed in `TeamPlanning::Events::PlanPricesFrozen`**
under the plan's key, so deleting the plan erases the copy with everything else. The copy
is tenant configuration and names nobody; a restore sets it aside rather than erasing it
([team-planning-design.md → Archiving as built](team-planning-design.md#archiving-as-built)).
Without key material, archiving records no copy and the plan prices live.

`PlanKeyStore` holds the keys in the `plan_encryption_keys` table, one row per key, and
answers RailsEventStore's key repository interface: `key_of`, `create` and `forget`.
Identifiers carry the tenant:

```text
tenant-<tenant_id>/plan-<plan_id>
tenant-<tenant_id>/plan-<plan_id>/person-<person_id>
```

- **Key material is encrypted at rest** with Active Record encryption, under the keys the
  tenant credential columns already use.
- **A key is read by its identifier's tenant**, because the mapper reads an event before
  a handler sets the tenant. An identifier from another tenant than the current one is
  refused.
- **`destroy_plan` and `destroy_person` write in the caller's transaction** and queue
  nothing, so the transaction that writes `PlanDeleted` or `PersonForgotten` can destroy
  the keys too, and a plan or person is never half forgotten.
  `TeamPlanning::SyncHandlers::DeletedPlanKeys` calls `destroy_plan` in the transaction
  that appends `PlanDeleted`, after the append, so it covers every path that deletes a
  plan and a later shreddable field on that event still finds its key. `OrgGraph::Forgetting`
  calls `destroy_person` inside its own per-person transaction, after it writes
  `PersonForgotten`.
- **A destroyed key stays destroyed.** Its row keeps no key material, and `create`
  refuses a new key for a deleted plan or a forgotten person, including a plan that never
  held a key for them.
- **It caches nothing**, so a destroyed key is gone for every reader at once. The mapper
  keeps no memo either: a cache held by an event outlives its read, and would outlive a
  destroy too.
- **Without Active Record encryption keys**, reading or minting a key raises
  `PlanKeyStore::Unavailable` with a plain reason. Destroying keys needs no key
  material, so forgetting still works, and nothing outside plans is affected.

### The declaration, the mapper and the guard

An event class declares its fields:

```ruby
class TeamPlanning::Events::NoteWritten < RubyEventStore::Event
  extend Shreddable
  shreddable :note, by: :plan        # the plan's own key
  shreddable :pay, by: :person       # the key of data[:person_id] in the plan
  # the key of the person the data names, or the plan's when it names none
  shreddable :reason, by: :person, person: ->(data) { data[:subject_id] if data[:about] == "person" }
end
```

`person:` names the data key that holds the person's id, or is a callable that takes the
data and gives the id. A callable that gives nil seals under the plan's key. A read model
column takes the same `person:`, called with the row, so a row can follow the key its
event chose.

- **`Shreddable::Mapper` wraps the event store's mapper.** On write it mints the key if
  needed, encrypts each declared field with AES-256-GCM and stores the ciphertext in
  Base64. The record's metadata gains `shreddable: { field => { cipher:, iv:,
  identifier: } }`. The tenant comes from the event's own `tenant_id` metadata. Writing
  for a deleted plan or a forgotten person raises `PlanKeyStore::Destroyed`.
- **A shreddable write runs in a transaction.** Taking the key locks the plan, and the
  person, until that transaction commits, so a destroy can't land between the key and
  the append. Outside a transaction the write raises.
- **On read it gives back a sealed `Shreddable::Value`**, which looks up its key on the
  first `reveal` or `removed?`. It opens as removed once the key is gone, or if the
  field is damaged. Each value looks up its key as it opens, with no memo, so a value
  opened after a destroy reads as removed. So an aggregate load, or a
  replayer passing over another tenant's events, never touches a key, and nothing reads
  differently where Active Record encryption has no keys until a line asks for the
  value. Revealing another tenant's value raises, as `PlanKeyStore#key_of` does. A nil
  field is stored as nil, with no key.
- **An event that declares nothing passes through untouched**: no query, no key lookup,
  and the same bytes at rest. `test/contexts/shreddable/storage_compatibility_test.rb`
  proves it against stored records of 36 event types, drawn from all five contexts. The
  other event types are untested there, so a change to the inner mapper should add
  records for the types it touches.
- **`Shreddable::Value#reveal` is the one way in.** The value prints as `[shreddable]`, and
  raises on `to_json`, `as_json`, YAML and Marshal, so it cannot reach a clear field of
  another event, a log line or a cache. A value is a JSON value: a string, number,
  boolean, array or hash with string keys. Anything JSON would read back differently,
  such as symbol keys or a date, is refused, because a subscriber would see one value
  and a replay another.
- **A declaration can't be skipped.** A subclass inherits its parent's fields, and data
  that names a declared field with a string key is refused rather than stored in clear.
- **Fields compose across a hierarchy, each under its own key.** Every Team Planning
  change inherits `shreddable :note, by: :plan` from the `Change` base, and a kind adds its
  own. A subclass may redeclare a field to change its key: a kind whose subject is a
  person declares `about_a_person`, which redeclares the note under that person's key, so
  `LevelSet` seals both its level and its note under the person's key and forgetting them
  removes both. A field that every change holds belongs in `Change::FIELDS`, which keeps
  it out of the end state a kind compares ([Notes](team-planning-design.md#notes)).
- **A field held apart from its kind chooses its key from the data.** `ChangePinned`,
  `ChangeNoted` and the two read models' note columns don't know the change's class, so
  they use the callable `TeamPlanning::ChangeKinds::NOTED_PERSON`: the subject, when the
  kinds that hold the facet are about a person, else nil for the plan's key. The note
  follows the key of the change's subject wherever it is stored, and a row computes the
  same identifier its event chose, so a rebuild copies the same bytes.
- **The event store browser at `/res` reads through `Shreddable::DisplayMapper`**, which
  shows each shreddable field as `[shreddable]`.
- **Every aggregate includes `Shreddable::AggregateRoot`** in place of `AggregateRoot`. Its
  apply strategy hands each `on` handler a copy with every declared field set to
  `Shreddable::Value.removed`. The aggregate still publishes the real event, so
  subscribers and projections get the real value. A test fails if an aggregate in
  `app/` includes the plain base.
- **The assessment and framework activity feeds copy whole event data** into payloads
  that the MCP tools serialise. A shreddable value there would raise, so a test keeps
  those contexts from declaring one until their feeds handle it.

**Rolling back.** A release before this one reads a shreddable record without raising.
It does not know the new event class, so the record reads as a plain
`RubyEventStore::Event`, and projections and the global replayer only read the types
they handle, so they never see it. An event class that an older release does know would
read its declared fields as Base64 strings, which is why a field must never be declared
shreddable on an event class that already has records. A new field is the exception,
since no record holds it in clear: the change kinds gained `note` this way. An older
release still unseals the note, since the record's metadata names it, but counts it as
part of the change's end state, and its status read raises on a noted change. Roll back
past 3.13b only before anyone writes a note.

## The guard

A shreddable value must never drive logic that would behave differently once it is gone.
Three layers enforce that.

### 1. Aggregates never see the value

An aggregate replays as if every key were already deleted. The aggregate base class
hands each `on` handler a redacted view of the event, with every shreddable field
replaced by the placeholder. That holds for replayed events and for events the aggregate
has just applied.

So an aggregate behaves the same with or without the key, by construction. It never has
the value to branch on.

Two things follow:

- A command can still validate its arguments. An argument is not replay.
- An aggregate cannot check that a shreddable value is unchanged. The Operation does
  that, against a projection. Comparing hashes is not a substitute: a hash of a salary
  is easy to brute-force.
- That check may skip a write only when the projection is current. A projection can lag
  the stream. If it has not applied the stream's latest event, the Operation writes the
  value. A redundant event costs nothing. A change dropped as "unchanged" is lost.

If a rule truly needs a value in order to decide, the value should not be shreddable.

### 2. A decrypted value is a wrapper, not a raw value

Projections and handlers do read these values. They receive them wrapped.

- **Opening it is a named call**, so every use can be found and reviewed.
- **It refuses to serialise in clear.** Writing one into a field that is not declared
  shreddable raises. A handler cannot copy a reason from one event into a clear field of
  another.
- **It prints as a placeholder**, so logs and error reports cannot leak it by inspection.

### 3. Specs that replay with the keys forgotten

Two shared specs, in `test/contexts/shreddable/replay_without_keys_test.rb`, run over
streams from every context built through the real handlers.

- **Aggregates.** Replay every aggregate with keys and without, and expect the same
  state, compared as Marshal bytes so a value still in clear raises. Each then runs one
  new command, and the new events must match too. Layer 1 should make this always pass.
  It catches a handler that bypasses the base class.
- **Projections.** Rebuild with every key forgotten and expect nothing to raise.

### 4. A read model holds the sealed form

A read model that copies a shreddable value declares the column with
`Shreddable::Column`: `shreddable_column :name, by: :plan, plan: :id`. The jsonb column
holds what the event store holds: the ciphertext, the IV, the cipher and the key's
identifier. It reads back as a sealed value that opens on `reveal`.

- **Destroying a key reaches every copy at once.** There is no scrub to run, no list of
  columns to keep complete, and no window between the destroy and the scrub. That holds
  even for a projection that lags or fails.
- **A rebuild needs no key.** The projection copies the sealed value from the event as it
  is, so a rebuild after the key is gone writes a value that opens as removed.
- **A live write copies the same bytes.** A sync projection receives the value in clear
  from the publish. The column stores the form the mapper just wrote for it, so a live
  write and a rebuild store the same bytes. A value the mapper never sealed is encrypted
  under the row's key, inside the transaction. `seal_column` does the same for a write
  that skips the model.
- **The identifier must be the row's own.** A sealed value copied into another plan's row
  opens as removed. A live value written there is sealed again under that row's key, so
  it reads in clear until a rebuild copies the event's sealed form and it opens as
  removed. A projection that copies a value across plans therefore can't rebuild what it
  wrote live. None does: each copies into the row of the plan the event names.
- **The column can't be ordered, filtered, grouped or plucked.** The query methods raise,
  and the column's type refuses any value in clear, so `update_all` and `insert_all`
  can't store one. Raw SQL isn't checked.
- **`Components::Shared::ShreddableText`** shows the value, or "Removed".

The cost is a key lookup each time a read shows the value. The other option was a
column in clear, scrubbed by every key destruction through a registry of such columns.
It reads faster, but a column someone forgets to register keeps the value for good.
`test/contexts/shreddable/column_test.rb` proves this with a test event and projection.

## Forgetting

Deleting a key is not enough. Read models, caches and exports hold decrypted copies.

1. An event says what was forgotten: `PersonForgotten`, `PlanDeleted`.
2. The key is deleted.
3. Projections handle the event and scrub what they hold. A full rebuild gives the same
   result, which is why the projection spec matters. A shreddable column has nothing to
   scrub: it opens as removed the moment step 2 commits.

Steps 1 and 2 are one database transaction. Keys and events live in the same database,
so there is no moment when the event exists and the key still does. A crash leaves both
or neither. Handlers and rebuilds run after the commit, so none can read the value once
the event is visible.

Step 3 does not depend on a job having been queued. A crash straight after the commit
can lose one. Each projection records the last event it handled, and catches up from
there when it starts and on a schedule. So a forgetting event whose handler never ran
is found and handled, late but certainly.

Step 3 is also safe to repeat. A scrub that fails is retried until it succeeds, and
running it twice changes nothing. Until it runs, a read model may still show the value to someone
already allowed to see it. That window is the handler's delay, and a deployment should
alert on a scrub that keeps failing.

A cache is a read model for this purpose. Anything that holds a decrypted value either
scrubs on the event or is rebuilt from a projection that does. Nothing may cache a
decrypted value without one of the two.

An export that has left Espalia cannot be recalled. Exporting a shreddable value needs
the permission to view it, and the export is recorded, so an organisation can say which
copies forgetting did not reach.

A projection that shows a forgotten value may say why it is gone, a deleted plan or a
forgotten person, where that helps its reader. The event in step 1 carries the reason,
so each projection decides for itself.

## Limits

- **One field, one key.** A note that names a second person is protected only by the key
  it was written under. A note on a unit, a position or a rule is under the plan's key, so
  forgetting a person it names leaves it readable. That is the accepted limit of free text
  ([#110](https://github.com/espaliahq/espalia/issues/110)), and the note tools tell
  planners to keep personal details out of it.
- **Encryption is not access control.** A reason still needs its own permission to view.
  Capturing reasons is opt-in per tenant, because some are special-category data.
- **Shreddable fields cannot be queried, in the event store or in a read model.** Query
  another column of a projection.
- **The key store is critical.** Losing it loses the data.
- **Backups bound how soon forgetting is complete.** Keys live in the application
  database, so a backup holds both a key and the values it protects. A value is
  unreadable in the live system at once. It is gone for good when the last backup taken
  before the key was deleted has expired. A deployment's backup retention is therefore
  its real time to forget, and should be stated.
- **A restore can undo forgetting. We accept that.** A backup from before a key was
  deleted brings the key back, and the event that recorded the forgetting is missing
  from it too. Nothing outside the backups records what was forgotten, so a restore
  does not carry it out again. The retention period repairs most of it without help: a
  person past their date is forgotten again on the next run. The date is worked out
  from the leaving date, which the restored events still hold or the next sync records
  again. Where the HRIS no longer returns the person, the sync dates their leaving from
  the day it notices, so they are forgotten one period after that day, later than they
  were due. Two cases need a person:
  someone forgotten on request before their date, and a deleted plan, which comes back
  and has to be deleted again. A deployment that restores a backup should check for
  both. One partial case is caught: `PlanEncryptionKey.outliving_forgotten_people`
  lists live keys for people the Org Graph has forgotten. A full restore brings back
  the person's row as it was, so nothing detects that.
- **Events already written stay in clear.** A field cannot be made shreddable after the
  fact without rewriting history. Plan and scenario names are the one exception, below.
  Covering existing evidence and comments is a separate migration with its own design.

## The one rewrite

Plan and scenario names were written in clear before
[#209](https://github.com/espaliahq/espalia/issues/209) made them shreddable. A name like
"Closing the Leeds office" says what a plan is for, so deleting the plan has to take the
name with it. Left in clear, every name written before [#209](https://github.com/espaliahq/espalia/issues/209) would outlive its plan.

`TeamPlanning::NameSealing` seals those names in place. It is the only rewrite of stored
events Espalia sanctions. Don't take it as precedent: the event store is append-only, and
everything else here depends on that. It was acceptable once because:

- **It touched little.** Four event types, `PlanCreated`, `PlanRenamed`,
  `ScenarioForked` and `ScenarioRenamed`, all in one context, and only the name fields
  within them. No deployed build ever wrote a `ScenarioRenamed`: renaming shipped broken
  and was fixed with its names sealed. The type is listed so a stray one can't stay in clear.
- **It changes nothing a reader relies on.** Each record keeps its id, type, stream,
  order and timestamps, and every byte but the name fields and the `shreddable` entries
  in its metadata. A test compares the rest byte for byte.
- **It reads back as a new write would.** The names are sealed by the same mapper, under
  the plan's key. A deleted plan's names are sealed under a key nobody keeps, so they
  read as removed. A plan deleted before deletion destroyed keys gets its tombstone
  first.
- **It is explicit.** `team_planning:names:dry_run` prints counts and changes nothing;
  `team_planning:names:seal` runs per tenant in one transaction, then rebuilds the plans
  and scenarios read models. A second run changes nothing. It never runs from a
  migration.

Run it once, after the deploy that ships [#209](https://github.com/espaliahq/espalia/issues/209),
while no one is renaming a plan or scenario. The task takes no lock a rename waits on, so a
rename during its rebuild can leave the old name in the plans or scenarios read model. A
scenario rename reads the current name from that read model, so it can also record no
previous name, or skip a rename it took for a repeat. A second run won't repair that, as it
finds nothing in clear and skips the rebuild; rebuild `team_planning/plans` and
`team_planning/scenarios` instead. A skipped rename wrote no event, so no rebuild brings it
back: rename that scenario again.

```bash
bin/rails team_planning:names:dry_run
bin/rails team_planning:names:seal
```

## Order of work

1. Per-plan keys, the declaration and the guard. Team Planning needs these.
2. Per-person keys, when the Org Graph first holds something sensitive.
3. Existing free text elsewhere in Espalia, if and when we choose to migrate it.

## Deferred

- Key rotation. Rotating the Active Record encryption keys that protect the key store
  needs Rails' re-encryption with the previous keys kept, not a swap.
- Holding keys apart from the event store, so no single backup has both. It would make
  forgetting immediate everywhere, at the cost of a second store to run.
