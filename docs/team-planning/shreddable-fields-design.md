# Shreddable event fields — design

> Status: proposal. Nothing here is built. [The index](README.md) lists the companion
> designs, the mockups and the plan.

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
| Shreddable by plan | A pasted salary, a note on a change, a scenario description | Encrypted under that plan's key. |

A field has exactly one key. Data a plan holds about a person is under the plan's key:
it is the plan's speculation, and it should go when the plan goes, even though the
person is still employed.

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
back as a forgotten-data placeholder. The exact API is to be checked against the
installed version.

We supply:

- **A key store in the application database**, one key per person and one per plan,
  namespaced by tenant. The library's own store is in-memory.
- **A declaration** that reads better than the raw schema, for example
  `shreddable :value, by: :plan`.
- **The guard** described below.

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

Two shared specs run over every stream fixture.

- **Aggregates.** Replay with keys and without, run the same commands, and expect the
  same state and the same new events. Layer 1 should make this always pass. It catches a
  handler that bypasses the base class.
- **Projections.** Rebuild with every key forgotten and expect nothing to raise.

## Forgetting

Deleting a key is not enough. Read models, caches and exports hold decrypted copies.

1. An event says what was forgotten: `PersonForgotten`, `PlanDeleted`.
2. The key is deleted.
3. Projections handle the event and scrub what they hold. A full rebuild gives the same
   result, which is why the projection spec matters.

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
  it was written under.
- **Encryption is not access control.** A reason still needs its own permission to view.
  Capturing reasons is opt-in per tenant, because some are special-category data.
- **Shreddable fields cannot be queried in the event store.** Query a projection.
- **The key store is critical.** Losing it loses the data.
- **Backups bound how soon forgetting is complete.** Keys live in the application
  database, so a backup holds both a key and the values it protects. A value is
  unreadable in the live system at once. It is gone for good when the last backup taken
  before the key was deleted has expired. A deployment's backup retention is therefore
  its real time to forget, and should be stated.
- **Events already written stay in clear.** A field cannot be made shreddable after the
  fact without rewriting history. Covering existing evidence and comments is a separate
  migration with its own design.

## Order of work

1. Per-plan keys, the declaration and the guard. Team Planning needs these.
2. Per-person keys, when the Org Graph first holds something sensitive.
3. Existing free text elsewhere in Espalia, if and when we choose to migrate it.

## Deferred

- Key rotation.
- Holding keys apart from the event store, so no single backup has both. It would make
  forgetting immediate everywhere, at the cost of a second store to run.
