# Org Graph — design

> Status: proposal, being built in `app/contexts/org_graph/`. Built so far: the person stream,
> which the HiBob sync records and updates ([#46](https://github.com/espaliahq/espalia/issues/46) to
> [#48](https://github.com/espaliahq/espalia/issues/48); rollout in
> [the first-sync runbook](../runbooks/org-graph-first-sync.md)), the structure stream
> ([#52](https://github.com/espaliahq/espalia/issues/52)) and membership
> ([#54](https://github.com/espaliahq/espalia/issues/54)), which nothing writes to yet. The
> units view ([#80](https://github.com/espaliahq/espalia/issues/80)) shows them, read-only, to
> tenant admins at `/tenant/org_graph` until the Org Graph screens are finished; MCP clients
> read the same tree through `org_graph_units`.
> [The index](README.md) lists the companion designs, the mockups and the plan.

The Org Graph is Espalia's best-known view of the organisation: who is in it, what they
do, who they report to and which teams they are in, with the history of how that
changed. The name is deliberate. It describes a shape and claims no authority. Most of
what it holds is another system's fact, mirrored; the rest is Espalia's best effort.

Espalia has part of this today. The HRIS sync keeps a `people` table current by
overwriting it. Nothing records what a row used to say, when someone left, or that a
department changed. Team membership is not held at all.

[Team Planning](team-planning-design.md) is the first module that needs more. It
states seven requirements, R1 to R7, and this design answers them. It is also useful
without planning: a live team is something reports and capability profiles can be read
by.

## The boundary

Holding these facts makes Espalia a small HRIS for whatever the real one lacks. We accept
that deliberately, inside these rules.

- **One provider per kind of fact.** The HRIS, an applicant tracking system, or Espalia. Espalia is the provider of last resort.
- **A polyfill yields.** When an integration starts supplying a fact, it takes over.
  Espalia's copy is compared, disagreements are shown, and the integration's value is used
  from then on.
- **Facts, never processes.** The Org Graph says that something is so. It never runs the
  workflow that makes it so. Onboarding, leave, contracts and pay belong elsewhere.
- **Nothing legal or financial depends on it.** No payroll, no statutory reporting.
- **A fact is added only when a feature needs it**, never because an HRIS would have it.
- **No finance model.** A person's cost centre is a label the HRIS supplies. The Org Graph
  does not model cost centres, accounts or any other financial or accounting identifier,
  and it does not hold the budget. Headcount budget is plan data for now.
- **Every fact Espalia holds shows its age:** who last confirmed it, and when.

One process does live in Espalia: approving a plan. Carrying it out in another system is
that system's process, started by a person or an agent there.

## Three kinds of fact

| Kind | Examples | Where it lives |
|---|---|---|
| Identifier | Name, email, external id | The `people` row only. Never in an event. |
| Operational | Title, level, manager, cost centre, country, FTE and employment type, start and leave dates, team membership | Events, in clear, keyed by person id. |
| Sensitive | A reason for a change, pay | Not captured in a first version. Later, as [shreddable fields](shreddable-fields-design.md). |

Events carry identity by reference, never by value. A manager is an id. So every stream
about a person is pseudonymous once the identifiers are erased, and still replays whole.

Operational facts are history we keep. The protection is in what the Org Graph refuses to
capture: named fields only, nothing else from the HRIS payload, and no free text about a
person.

An event written in clear stays in clear. So until shreddable fields exist, the Org Graph
captures nothing that would need them. Sensitive facts arrive later as new fields that
are shreddable from their first event.

## Streams

### One stream per person

`tenant-{id}/Person-{person_id}`

| Event | Records |
|---|---|
| `PersonRecorded` | The first time the Org Graph sees a person, with the facts as they stood. History starts here. |
| `PersonJoined`, `PersonLeft`, `PersonReturned` | Employment status, with the date. |
| `StartDateChanged` | The start date of someone recorded and not left, when it was unknown or differs. |
| `TitleChanged`, `LevelChanged` | The HRIS's own title and level, before any mapping to a framework. |
| `ManagerChanged` | The new manager's id, or none. |
| `CostCentreChanged`, `SiteChanged` | The cost centre as the HRIS names it. |
| `EmploymentChanged` | FTE and type. |
| `MembershipSet`, `MembershipEnded` | A unit, an allocation, and the role played there. |
| `MembershipMoved` | That a membership moved to another unit, keeping its terms. |
| `FactConfirmed` | That a fact Espalia holds is still true, and who said so. |
| `PersonForgotten` | That the identifiers have been erased. |

Every event carries the provider that supplied the fact, the date it took effect, and,
where it came from a plan, a reference to the plan's change.

Two rules hold for the status events:

- **`PersonReturned` is only for the same person.** The HRIS must show the same external id, and the person must not have been forgotten. Anyone else is a new person with a new id. The sync never merges a row into a person by email when that person already holds another external id: it skips the row and reports it for an admin to resolve.
- **Returning restores no memberships.** A returner comes back with none, like a new person.

Dates for the status events and the start date:

- **`PersonJoined` is the move from pending to employed, effective on the start date** when the HRIS holds one, else the sync's date. A hire the HRIS shows before their start date stays pending and joins on the first sync on or after it.
- **`PersonLeft` is effective on the HRIS termination date** when it holds one, else the sync's date. A leaver whose termination date arrives later, or changes, gets a second `PersonLeft` on that date. A termination date before the start date contradicts it, so the sync drops it and dates the leaving by the sync.
- **`PersonReturned` is effective on the start date when it falls after the leaving**, else the sync's date, since an HRIS may still hold a returner's first start. A leaver whose rehire has not started yet stays left, and their facts are not compared until they return.
- **`StartDateChanged` supplies or corrects the start date of someone recorded and not left**, effective on that date. `PersonRecorded` carries the start date when the HRIS sends one.
- **The history projection reads employment as beginning on the start date** when one is held, not on the day the sync first saw the person.
- **Country stays absent** until the tenant's field mapping names a field for it. HiBob gives a site no country. Once one is mapped, a site is compared only when HiBob sends both.

### One structure stream per tenant

`tenant-{id}/OrgStructure`

| Event | Records |
|---|---|
| `TaxonomyDefined` | The tenant's names for its levels. Redefining it is a change like any other. |
| `UnitCreated`, `UnitRenamed`, `UnitMoved`, `UnitRetired` | A unit's life. Retiring a unit ends each membership in it on that date, unless a succession moves its members to the unit that carries on. |
| `UnitSucceeded` | That one or more units carry on from one or more others: a split, a merge, a replacement. |
| `UnitOwnerAdded`, `UnitOwnerRemoved` | Who may edit the unit. |
| `LevelProviderSet`, `FactProviderSet` | Who supplies a taxonomy level, or a kind of person fact. See [Providers and provenance](#providers-and-provenance-r5). |

A succession can retire its predecessors in the same step. Each such `UnitRetired`
names the succession and its successors, and its members move rather than leave:

- **One successor (a merge or a replacement):** every open membership moves to it on
  the succession date.
- **Several successors (a split):** whoever issues the split may name a successor per
  person, and those people move. Anyone not named has their membership ended on that
  date, so they appear in the "in no team" tray for someone to place. The handler never
  guesses.
- **Placements are not stored on the structure events.** They are ordinary membership
  commands issued with the split, sharing its cause. The split step in the unit drawer
  (5.6, [#138](https://github.com/espaliahq/espalia/issues/138)) and applying a plan
  (7.3) supply the names. The drawer's step lists who will be in no team before it applies.

A plan applies a succession through `OrgGraph::StructureCommandHandler#apply_succession`,
built with the approval as its `cause_id:`. In one transaction it moves the people the plan
names, records the succession and retires the predecessors, so every event shares the
approval and the plan change. The approver must be able to change every unit in it. A
placement outside the successors, or for someone in no predecessor, applies nothing.

`OrgGraph::SyncHandlers::RetiredUnitMemberships` does this when a unit retires, in each
member's own stream. Every `MembershipEnded` or `MembershipMoved` it writes has the
retirement as its cause. A plain retirement ends every open membership in the unit on
the retirement date, each as its own provider holds it. A membership that began after
a backdated retirement closes on the day it began. A unit with live sub-units still
can't be retired, so its members stay where they are.

Units carry their provider too: a unit mirrored from an HRIS team is read-only in
Espalia, and units Espalia holds can hang beneath it. A mirrored unit also carries the
provider's own reference for it, so a rename in the HRIS is recognised as a rename. See
[Which HRIS field a fact comes from](#which-hris-field-a-fact-comes-from).

Membership is a fact about a person, so it lives in the person's stream. A unit's
members are a projection.

`OrgGraph::PersonAggregate` holds one membership per unit, so a person can be in several
units, each with its own allocation and role. An allocation is a share of the person's
time, above 0 and at most 1, or none when the provider states none, as an HRIS field
doesn't. Allocations across units are not summed or capped here: an over-allocated person
is for a plan's checks to flag. The same terms from the same provider write nothing. A
person who has left can't join a unit, and a membership can only be set in a live unit.
`MembershipEnded` dates the last day of one membership and leaves the others.
`MembershipMoved` carries a membership to another unit with its allocation, role and
start, so a move is one fact and the person is never ended and added again. A person
already in the destination keeps the membership they have there. For them, and for a
person who has left, the membership they came from ends instead. Leaving ends every membership
on the leaving date; see [How the sync writes](#how-the-sync-writes).

`OrgGraph::Projections::Members` projects the current memberships into `org_memberships`.
An ended membership has no row; its history is in the person's stream. `Person.in_no_unit`
lists the people with no membership of a live unit, for the "in no team" tray.

`OrgGraph::Projections::PeopleColumns` projects `job_title`, `manager_id` and `status` onto
`people` for a tenant cut over to the Org Graph, and writes nothing for any other tenant.

`OrgGraph::StructureAggregate` holds these rules:

- **A change comes from the unit's own provider.** A command names its provider, which
  defaults to Espalia, and a unit refuses a change from any other. So an HRIS team
  rejects an edit made in Espalia and still takes the sync's rename.
- **A parent sits at a higher level**, is live, and is never the unit itself or a unit
  beneath it. A unit with live sub-units can't be retired.
- **A unit comes from its level's provider.** Levels an HRIS supplies sit above every
  level Espalia holds, so the same holds for top-level units as for a parent and its
  child.
- **A mirrored unit carries its reference, and one Espalia holds has none.** Two live
  units never mirror the same reference.
- **A taxonomy level keeps its id through a rename.** A level that still holds a unit
  can't be dropped, and the levels in use keep their order.
- **An unchanged name, parent or taxonomy writes nothing**, so a sync that finds no
  difference adds no event.
- **Succession links only units that exist.** Its successors are live, no unit
  succeeds itself, and no chain of successions loops back. Restating one exactly writes
  nothing. Retiring a predecessor through it follows the usual rules: the predecessor's
  own provider, and no live sub-unit left behind outside the succession.

`OrgGraph::Projections::Structure` projects the current tree into `org_units` and
`org_taxonomy_levels`, and each succession's links into `org_unit_successions`, so a
reader can list a unit's predecessors and successors. The history that reads "was X" is in the stream:
`UnitRenamed` carries the previous name, and the history projection (R4) will read it.

### The shape of the organisation has a history too

A reorganisation changes the units themselves: what exists, what each is called, where
it sits, even what the levels are named. That is tracked like any other fact.

- **A unit has a stable id.** Its name and its parent are facts about it, each with an
  effective date. A renamed unit is the same unit, and its history reads "was X".
- **Succession is stated, not guessed.** When a plan splits a team or merges two,
  applying it writes `UnitSucceeded`. A reader can follow a team back through a
  reorganisation even when no name survived.
- **Events that belong together say so.** Every event applied from a plan carries that
  plan's approval as its cause. The history can then show one reorganisation as one
  thing, not as forty unrelated edits.
- **Structure reads as of an instant**, the same way the roster does. Last year's team
  profile is read against last year's teams.

### Who may change it

The whole tenant can see the Org Graph, as it can an org chart. Editing the facts Espalia
holds is open to:

- **A tenant admin**, always.
- **An Org Graph editor.** A tenant-level role for the people team.
- **A unit's owners.** A unit can have several, with none primary: a product manager and
  an engineering manager can both own a squad. An owner may edit the unit and the units
  beneath it. A unit with no owner of its own inherits its parent's.
- **A person's manager chain**, for that person's memberships only. A design lead can
  place their designer in a squad they do not own.

Every Org Graph command checks this when a person runs it, and a refusal says who may
make the change. The HRIS sync and the system's own work, such as a retirement moving
its members, run as the system and are not checked.

**Trust, then verify.** No change waits for anyone's acceptance. A manager places their
report in a squad and it is so. What keeps that honest is visibility: every change is an
event with who made it and when, and the Org Graph shows an activity sidebar like the
one a framework has. A unit's owners see what changed in their unit and can change it
back.

Ownership is always stated. It is never derived from reporting lines or from a role in
the unit, because a cross-functional team has no single line to derive it from. When a
unit's last owner leaves, the unit is flagged and inherits its parent's owners until
someone is named.

`UnitOwnerAdded` and `UnitOwnerRemoved` live in the structure stream, and any live unit
takes owners, one an HRIS supplies included. An owner leaves when they are removed, or
when they leave the company and their `people` row goes inactive. That is read when the
owners are asked for, so leaving writes no ownership event. A unit nobody up its chain
owns is flagged too (`OrgUnit#needs_owner?`).

### What changed in a unit

`OrgGraph::Projections::UnitActivity` writes one entry per change to a unit or to one of
its memberships into `org_unit_activities`, and `OrgUnitActivity.for_unit(unit_id)` lists
them newest first. Each entry says who made the change, or which provider supplied it,
what it changed from and to, when it took effect and when the Org Graph learned it. A move
between units is an entry in each, naming the other. A succession is an entry in every
unit it names. Each entry keeps its event's `correlation_id`, its cause: the approval a
plan's changes share, or the request that made one direct edit. It keeps `causation_id`
too, though RES rewrites that inside sync handlers, so it names the event that triggered a
handler rather than the cause. An entry also keeps the `plan_id` and `plan_change_id` its
event carried, so an approved change names the plan change behind it.

**One cause reads as one entry.** `OrgUnitActivity.feed(unit_id, page:)` groups a unit's
entries by cause into `OrgUnitActivity::Group`s, newest first, and pages by group, so a
page never splits one. A group's `summary` says what it did in a sentence: "split Payments
into Billing and Ledger" for a succession, otherwise "moved 10 people out and removed 2
people". Its `parts` are the entries underneath. A group needs no table of its own: it is
read from the entries as they stand, so it rebuilds with them. A HiBob sync writes one
cause per run, so a run reads as one entry in each unit it touched.

**Changing it back writes the inverse.** `OrgGraph::ChangeBackHandler` undoes an entry
with a new event that carries `changed_back_id`, the event it reverses. Nothing is
deleted: the feed keeps both, and marks the original with the change that undid it. Ending
a membership puts it back on its earlier terms, a rename takes back the old name, and a
move goes back where it came from. The inverse takes effect when the original did, so the
fact reads as if the change never happened, unless the caller names a date. It goes through the ordinary handlers under the same actor, so it is refused
wherever the change itself would be. It is refused, too:

- for a change another provider supplied, which belongs in that provider;
- for a change already changed back;
- for one a later change to the same fact has overtaken, in any unit it touched, so a
  correction never silently undoes someone else's;
- for creating, retiring or succeeding a unit, which reshape the structure rather than
  change one fact.
- when the aggregate would write something else, such as ending a moved membership
  because the person has since left.

**A group changes back whole, or not at all.** `change_back_group(cause_id)` undoes every
entry of one cause, across every unit it touched, newest first, so a later part never
blocks an earlier one. Every part must pass the checks above, and a later change counts
against a part only when it came from outside the group. One refused part refuses the lot
and writes nothing. Once one part has been changed back alone, the rest go back one entry
at a time. A unit's feed shows only that unit's parts of a cause, but changing the group
back reverses the cause in every unit it touched, so the sidebar (5.4) must say so. An approved succession is always refused, since it retires a unit. The
inverses share one new cause, so the change-back reads as one entry too.

Every write to a stream holds a lock on it until its transaction ends: the person's stream
for a membership, the tenant's structure stream for the rest. A change-back takes those
locks before it checks anything, the structure's first and then each person's in id
order, so no change to the facts can land between the checks and the inverses.

The feed starts from the Org Graph's first event, so a deploy that adds it rebuilds it
(`REBUILD_ON_DEPLOY=org_graph/unit_activity`) wherever Org Graph events exist. Without that
history a membership's earlier terms would be missing.

The sidebar that shows this is 5.4.

### Keeping a fact current

An HRIS keeps its own facts fresh. A fact Espalia holds stays true only while someone
keeps it so, so each one shows its age.

- **`FactConfirmed` says a fact still holds**, and who said so. It names the fact, a
  membership by its unit or a person fact by its key, and never copies the value, so a
  confirmation can't disagree with the fact. Only a fact Espalia holds, for someone who
  hasn't left, can be confirmed, and a membership only in a live unit. Like any person
  command, a confirmation is refused once the tenant hands the fact or the unit to an
  HRIS, even before the next sync rewrites it.
- **A handover ends a fact's age.** The HRIS's next write names it as the provider, and
  the fact drops out of `org_fact_ages`.
- **A fact is stale** when nobody has changed or confirmed it within the tenant's
  threshold, `Tenant#org_graph_config.staleness_days`, a quarter by default.
- **Age runs from when the Org Graph learned of a change**, not from its effective date,
  so a membership backdated to last year doesn't arrive already stale.
- `OrgGraph::Projections::FactAges` keeps each fact's last change and confirmation in
  `org_fact_ages`, and `OrgFactAge.stale(tenant)` lists the stale ones, oldest first. A
  leaver's facts are never listed, nor a membership of a retired unit. Changing one half
  of a pair, such as a site, leaves the other half's age alone.

The flags and confirm buttons are 5.5. Units' own facts, their names and parents, have no
confirmation yet.

### What happens to `people`

The identifier columns stay as they are: mutable, written by the sync, and the only place
a name or an email is stored. The other columns become a projection of the person's
stream.

In practice that means `job_title`, `manager_id` and `status`, one tenant at a time. A
tenant is cut over once every person has a stream that starts with `PersonRecorded` and a
rebuild reproduces every row ([runbook](../runbooks/org-graph-people-cutover.md)). Until
then the sync writes those columns itself. The other non-identifier columns stay with the
sync for now: `department` until a level is mirrored from an HRIS field (6.7), and
`level_id`, `role_id` and `hris_level_ordinal` until E9 moves the framework mapping.

The existing Person Development events (`PersonRoleChanged`, `PersonLevelChanged`,
`ReportingManagerRecorded`) are about a person's place in a framework and stay. They
exist only for people mapped to a framework role, which is why they cannot serve as the
Org Graph.

In a first version the sync writes both: the Org Graph, and Person Development as it
does today. Later the flow becomes HRIS, then Org Graph, then Person Development: a
handler on the Org Graph's events applies the title mapping and issues the Person
Development commands. That gives one write path, serves any future provider, and records
the loss of a manager, which today is dropped. It is its own step because assessments
depend on the logic it replaces.

## How the sync writes

Today the adapter assigns attributes and saves. Instead it compares each incoming row
with the Org Graph's current projection and issues a command for each difference. A sync
that finds nothing changed writes nothing.

A person who disappears from the HRIS gets `PersonLeft` once, dated by the first sync
that misses them. For someone recorded as employed whose start date is still ahead, it
is dated by that start date, since nobody leaves before they start; a pending hire who
disappears leaves on the date of the sync. Someone who comes back keeps their stream and
gets `PersonReturned`; the earlier `PersonLeft` stays in history as what we believed then.

A failed or partial sync marks no missing person as left, in the Org Graph or in
`Person.status`, so both read the same set of absent people. Someone HiBob still returns
as inactive is Pass 2b's, and leaves whatever the brake decides. A sync is failed or partial when any of these holds
([#51](https://github.com/espaliahq/espalia/issues/51#issuecomment-6856499516)):

- a page request fails;
- the response is empty;
- a page has no employee list;
- the employed people missing from the response are more than 10% of the tenant's
  employed HRIS-held people **and** more than 5 people (the brake). People already
  inactive in `Person.status` do not count towards it. The sync result reports the
  count and the thresholds.

A response that passes those tests and omits a few people, at or below the brake, is not
partial: those people have left. The brake is deliberate: a partial response looks
exactly like a mass leaving, and a leaving stays in history. The next sync decides
afresh. There is no override or per-tenant setting; a story for a manual override can
follow if a real mass leaving ever needs one.

One gap remains. Before a tenant's people columns are cut over (story 1.4), if the Org
Graph write fails for one person, the sync still marks them inactive, so Pass 3b still offboards them from open cycles and framework assignments on
time. For a while the two disagree: the person is
inactive but still employed in the Org Graph. The next sync that misses them writes the
`PersonLeft`, dated that day, unless that sync is empty, trips the brake or fails the write
again; then the one after tries.

After cut-over the stream is the only writer of `status`, so Pass 3 does not mark that
person inactive around it, and nothing retries within the run. A failed absence write
delays offboarding by one sync and is reported in the result's errors. The next sync
decides absence afresh and writes the `PersonLeft`, which marks them inactive, and Pass 3b
offboards them.

Leaving ends every open membership on the leaving date (story 2.5).
`OrgGraph::SyncHandlers::LeaverMemberships` runs on `PersonLeft`, as the system, and ends each from the person's stream in the leaving's
transaction, with the leaving as each end's cause. A membership that changed after a backdated
leaving ends on the day it changed. A later `PersonLeft` that corrects the date ends nothing again.
A returner comes back with no membership, and a new person appears with none. No position is
created for anyone automatically. A leaver who was a unit's only owner leaves it flagged as having
none, as [Who may change it](#who-may-change-it) describes; leaving writes no ownership event.

The first sync after this ships writes `PersonRecorded` for everyone. Nothing earlier can
be reconstructed.

## Reading as of an instant (R4)

Each fact has two times: when it took effect, and when the Org Graph learned it. A history
projection keeps one row per fact, per period of validity, per time learned. A correction
adds a row with a later learned time. It never overwrites the row it corrects, or the Org
Graph could no longer say what it knew before. From it:

- `OrgGraph::AsOf` gives the roster, the structure and the memberships in effect on a day.
  By default it reads what the Org Graph knows now, so a later day includes the changes
  already recorded for it: a hire who starts then, a move or a leaving scheduled for it.
  With `known_on` it reads what was known at the end of that day in UTC. Tenants hold no
  time zone yet, so for a tenant in Sydney the day ends at 10 or 11 in the morning local
  time, and a fact learned that afternoon counts as known the next day. People come back as
  ids, and callers join names, so a forgotten person reads as a former member. MCP clients
  read it through `org_graph_as_of`.
- `changes_between(a, b)` lists the facts that differ.

"As of" is by the time the Org Graph learned a fact. A plan pinned to last Tuesday sees what
was known last Tuesday, even if a backdated correction arrived since. The correction
shows up as drift.

The projection is `org_graph/history`, and it writes one table, `org_fact_periods`. A row
names its subject (a person, a unit or a succession, by id), the fact, a key (the unit,
for a membership; the person, for a unit's owner; empty otherwise), the value and its
provider. Two windows place it:

- `effective_from` to `effective_to`, the days the value held. The end is exclusive, and
  open while the value still holds.
- `learned_at` to `superseded_at`, the time the Org Graph believed the row. An event that
  changes a period supersedes it at the event's time and adds its replacement. Rows are
  never edited, so `known_at(instant)` and `in_effect_on(date)` are plain range checks.

The dates follow the events:

- A membership's end, a unit's retirement, an owner's removal and a leaving date are each
  the last day, so the next period starts the day after.
- A leaving ends whatever came after it: a later status, or a return dated after it.
- A move ends one membership and starts the other on the same date.
- Employment starts on the held start date when there is one. A start date before the
  latest leaving belongs to an earlier spell and changes nothing.
- A return restores nothing: a membership ended by leaving stays ended.
- A change-back on the same date as the change it reverses withdraws that change, as
  though it never took effect. On a later date it is an ordinary change.
- `PersonForgotten` changes nothing here. The rows hold ids, and the history stays.

Production already holds events of every type it reads, so the deploy that ships it needs
`REBUILD_ON_DEPLOY=org_graph/history` to fill it. Without it, predeploy's `verify` stops
the deploy.

## Applying a change (R6)

Facts Espalia holds change in two ways. Both issue the same commands.

- **From a plan.** Approval applies the plan's changes, each tagged with the change it
  came from.
- **Directly.** Someone permitted edits the structure. A first version needs little
  here, because a first plan applied whole creates the structure.

Every command takes the plan change it came from as two opaque ids, `plan_id` and
`plan_change_id`, and writes both on each event it produces. A retirement's member
moves carry them too. A direct edit carries neither, nor does any event written before
the reference existed. The Org Graph never reads them.

The approval is the cause. A handler built with `cause_id:` gives every event it writes,
a sync handler's included, that id as its `correlation_id`. Without one, events keep the
request's, so one direct edit still reads as one change. The activity feed groups by
`correlation_id`. Undoing a change is a new change with its own cause.

Either way the change carries an effective date, so a move can be recorded as having
happened on the first of the month. A change may be backdated, but a fact's dates stay in
order: a membership can't end before its latest change or restart before the last one
ended, and a unit can't change before it was created, retire before its latest change, or
sit beneath a parent that didn't yet exist.

Facts another provider holds cannot be changed here. They change when the sync says so.
Every person command is refused unless its provider holds what it writes: the tenant's
setting for that kind of fact, or for a membership, its unit's own provider. A unit keeps
the provider it was created with, which was its level's then, and a membership moves only
into a unit the same provider supplies. The setting reaches only people who carry that
provider's external id: anyone else, added by hand or with an account, is Espalia's for
every fact, so Espalia edits them and the sync never writes them. The error names the
provider that does. The sync reports a refused person and carries on with the rest.

## Providers and provenance (R5)

Each kind of fact names its provider, per tenant. For structure the setting is per
taxonomy level, so an HRIS can own departments and teams while Espalia holds the squads
beneath them.

The setting lives in the structure stream as `LevelProviderSet` and `FactProviderSet`,
so each change keeps its date and who made it. A fact or a level has exactly one
provider, and it's Espalia until another is set. A unit comes from its level's provider,
and the levels an HRIS provides sit above every level Espalia holds. That check on the
setting replaces the first version's check on each unit. A level that holds live units
keeps its provider until a handover (6.8) moves it. A new level names its provider when
the taxonomy adds it, so a level can be added above one an HRIS provides.

The kinds of person fact, each naming the events it covers:

| Kind | Events |
|---|---|
| `employment_status` | `PersonJoined`, `PersonLeft`, `PersonReturned`, `StartDateChanged` |
| `title`, `level`, `manager`, `cost_centre` | `TitleChanged`, `LevelChanged`, `ManagerChanged`, `CostCentreChanged` |
| `site` | `SiteChanged` (site and country) |
| `employment` | `EmploymentChanged` (FTE and type) |

The HiBob sync writes `employment_status`, `title`, `level`, `manager`, `site` and `employment`. Each must name the HRIS as its provider, or its writes are refused; how it comes to is below. `cost_centre` stays Espalia's until the field mapping (6.4) names a field.

An HRIS supplies some facts by default: employment status, title, level, manager, site
and employment
(`OrgGraph::StructureAggregate::HRIS_FACTS`). Saving a configured HRIS hands it each of
those whose provider nobody has chosen, and a predeploy task does the same for tenants
already connected. This records what was already true, since the sync has always
overwritten those columns on `people`; it is not a handover. A fact whose provider was
ever chosen keeps it, so a re-run reaches only facts added to the list since.
Disconnecting hands nothing back: that is a handover too.

The field a fact is read from is part of the same setting: `FactProviderSet` carries `fields`, so naming a field names its provider too. Cost centre and a site's country can be mapped today.

When a provider is added for a fact Espalia has been holding, the two are compared.
Agreement is silent. A disagreement is listed for someone to resolve, and the provider's
value becomes the Org Graph.

### Which HRIS field a fact comes from

A fact the HRIS provides names the field it is read from, per tenant. Common facts
start with a sensible default, such as the HRIS's own job title and department fields.
An admin can choose another.

- **Fields are chosen from a list, never typed.** The settings screen reads the HRIS's
  field catalogue and offers its fields by name. Nobody pastes a field id.
- **A structure level names one field.** When the HRIS provides a level, each distinct
  value of its field is a unit at that level, and a person's value is their membership.
  A blank value means the person has no unit at that level.
- **The screen shows what a field gives before it is chosen:** how many units, how many
  people, how many blank. A field that yields one unit per person is plainly the wrong
  one.
- **A unit sits under the unit above that its people share.** The HRIS states no parent,
  so the parent is read from the people.
- **Levels the HRIS provides sit above every level Espalia holds.** Espalia's units can
  hang beneath a mirrored unit. A mirrored unit never hangs beneath one of Espalia's.
- **An HRIS field gives one unit per person per level.** It carries no allocation and no
  role. A person split across two teams can only be held by Espalia.
- **Choosing a field for a level Espalia has been holding is a handover.** The two are
  compared as above, and the disagreements are listed. Each unit's match is suggested by
  name and confirmed by a person (6.8, below).

A list field keeps a unit through a rename. Its values have ids of their own, so the
unit's external reference is the value's id, prefixed with the field's path
(`work.department/261985129`) so two levels' values can never collide. A new label is
`UnitRenamed`: the history reads "was X". A free-text field has only its text, which
becomes the reference in the same way. A renamed value there looks
like one unit emptying and another appearing, and the Org Graph does not infer a link.
Someone can state the succession. The screen says which kind each field is.

#### How a sync mirrors a level (6.7)

`Hris::LevelMirror` runs after the people are recorded, one level at a time, top first.

- **Withheld is not blank.** A record that leaves the field out changes nothing for that
  person. A field sent empty ends their membership at the level.
- **Units come and go with the list.** A value someone holds is created as a unit. A
  list item that is archived or gone retires its unit, and the memberships it held end
  with it. A text value retires once nobody holds it and no record withheld the field.
- **A hand-added person keeps their place.** Espalia may put someone the HRIS doesn't
  know into a mirrored unit, and the sync never touches that membership.
- **A parent needs every voice and two syncs.** A unit sits under the unit above only
  when all its people with a value there agree. A unit nobody reads a parent for keeps
  the one it has. A new parent is written only when two syncs in a row read the same
  one; the first reading waits in `hris_unit_parent_proposals`.
- **Brakes.** Ended memberships and retired units each stop at the absence brake people
  have: more than 10% and more than five, and none of that kind is written. The members a
  retiring unit still holds count as ended memberships, so a tripped membership brake
  holds those retirements back too. A sync that can't read the field lists mirrors nothing.
- **One cause per change.** Each unit change and each person's membership change is its
  own correlation, written by SYSTEM with the HRIS as provider and dated the sync's day.

A unit whose people sit under different units above keeps its parent and is listed in
the sync's result as split, for someone to resolve. Espalia never picks a majority.

#### Handing a level over, and back (6.8)

`Hris::LevelHandover` compares a level Espalia holds with the field it would come from,
then switches it. The operations are `integrations_hris_level_handover` (the comparison),
`integrations_hand_over_hris_level` and `integrations_hand_back_hris_level`. The settings
screen (6.9) hosts them.

- **Suggested by name, confirmed by a person.** Each unit gets the value whose label
  matches its name, and the values its members hold, with how many hold each. Nothing is
  matched until an admin confirms a value for the unit.
- **Every unit is resolved first.** A unit with no value is succeeded into a matched unit,
  which moves its members there, or retired. The comparison also lists values with no
  unit, people whose value differs from their unit, people the HRIS sends blank, and
  people added by hand. Those may stand: the switch moves, ends or keeps them as a sync
  would. A value matches one unit only, and a unit that can't retire today (it has live
  sub-units, or a change dated later) blocks the switch until someone deals with it.
- **One cause, one transaction.** The switch records the field as the level's source,
  gives each matched unit its value (`UnitHandedOver`), writes each succession and
  retirement, hands the HRIS the memberships of the people it reads, and mirrors the
  field once. A failure anywhere writes nothing. A new unit has no parent until a sync
  reads one. Each unit's feed shows the handover as one entry under that cause, naming
  the provider and the field it now comes from, never the value; handing back reads the
  same way.
- **A fingerprint refuses a stale comparison.** It covers the field's values, the units,
  the memberships, the matches and the resolutions. The switch is refused if any of them
  changed since the admin read it.
- **The brake asks for a count.** The comparison counts the memberships the switch ends
  with nothing in their place, and the units it retires. Over the brake, the switch goes
  ahead only when the caller passes both counts exactly as the comparison gave them, as
  forgetting confirms its count. The sync's own brake is unchanged.
- **Over MCP only with approval.** The comparison is a plain read. Both switches need
  in-app approval and the comparison's fingerprint, so an agent cannot switch on a
  comparison nobody read.
- **Handing back undoes no history.** The level and its units become Espalia's again and
  lose their references. Units and memberships stay as they are; successions and
  retirements made by the handover stand. The brake does not apply in reverse.

#### What the sync needs for this

The HiBob adapter is most of the way there, and the gaps are small.

- It can already read the field catalogue and the named lists. Nothing calls either yet.
- It requests a fixed set of fields, with department the only structural one, plus the
  level field and the fields the tenant's mapping names (6.4).
- The level field is set by pasting its raw id. The picker replaces that.
- It asks for both the stored value and the display text. The mapper reads them as a
  pair (`ResponseMapper#field_value`), and the mirror keys units on the stored id.
- It requests the field each mirrored level names, beside the others.

A unit whose people sit under two different units at the level above keeps its parent
and is listed for someone to resolve, as a disagreement is (settled in 6.7).

#### Are HiBob's list values stable ids?

Yes, for items with numeric ids, which is what a company's own list items get. HiBob's
documentation says so, and a read-only check against one live deployment confirms the
parts it could see. One case is still open: older items whose id is their original
name. The sandbox check in [#61](https://github.com/espaliahq/espalia/issues/61) would
settle it. Each adapter needs the same check before a rename can be trusted to it.

What the documentation confirms:

- **A list field stores the item's id, not its label.** [Fields and lists
  metadata](https://apidocs.hibob.com/docs/fields-metadata) says a list field holds "the
  list item's string ID rather than its value", and "List items - store the backend ID".
  The id is text for HiBob's own lists and a number for items a company added.
- **Department is such a field.** The same page lists `work.department` as type `list`,
  with `listId` `department`. The [read
  contract](https://apidocs.hibob.com/docs/people-read-api-contract) shows its machine
  value as a number: `"/work/department": { "value": "209192163" }`.
- **A rename changes the label and keeps the id.** The fields page warns that an id
  which looks like a label "may have been renamed, and will have a different display
  value". Its example item keeps `"id": "Animals"` while `value` and `name` become
  `"Pets"`. [Updating a list
  item](https://apidocs.hibob.com/reference/put_company-named-lists-listname-itemid)
  addresses the item by its id, and "Providing a name will rename the list item value."
- **The adapter already receives both.** It sends `humanReadable: "APPEND"`, which per
  [people search](https://apidocs.hibob.com/reference/post_people-search) adds a
  `humanReadable` node beside the machine values. `ResponseMapper` reads the label from
  that node. The raw employee, id included, is already kept in `hris_raw_data`.

What one live deployment confirms, read-only:

- **A person's stored department is the list item's id.** Every stored `work.department`
  matched an item id in the department named list, and that item's name matched the
  person's human-readable label.
- **A picker can tell a list field from free text.** The field's metadata has type
  `list`, and `typeData.listId` names the list to read.
- **A list item says when it is retired.** Each item has `id`, `name`, `value`,
  `archived` and `children`. `archived` is the signal to retire a mirrored unit.
  `children` means a list can be a tree; the department list seen was flat.

What is still open:

- **Item ids are mixed.** Newer items have a numeric id that differs from their name.
  Older items use their original name as their id, so id, name and value are the same
  text. HiBob's `Animals` example suggests such an item keeps the old text as its id
  through a rename, but nothing read-only can show it.
- **A rename in HiBob's settings screen is assumed to do what the API does.** The
  documentation describes the API. An admin is more likely to rename in the screen.

Neither changes the design. A unit's external reference is the item's id, whichever
kind it is. If a legacy item's id did change on a rename, the sync would see one unit
emptying and another appearing, which the design already handles: someone states the
succession. Archiving a department and adding a new one looks the same, since the new
item has a new id.

For whoever builds 6.5: the named-list response carries the same entries under both
`items` and `values`, and each person also has a flat `/work/department` key holding
`{"value": <stored id>}`, with no human-readable text.

The check that would settle the rest, against a sandbox with two disposable departments,
one with a numeric id and one legacy item whose id is its name:

1. `POST /v1/people/search` with `fields: ["root.id", "work.department"]`,
   `humanReadable: "APPEND"` and a filter on a test person in each department. Note
   `work.department` and `humanReadable.work.department`.
2. Rename both departments in HiBob's settings screen, not through the API.
3. Repeat the search, and `GET /v1/company/named-lists/department`.

A rename is stable if `work.department` is unchanged, the human-readable label shows the
new name, and the named list shows the same item id with the new `value`. Record the
result for each kind of id separately.

## Forgetting a person (R7)

- A tenant sets a retention period for people who have left. The default is seven years from the
  leaving date. "Never" is allowed.
  - The period is `Tenant#org_graph_config.retention_years`, beside the staleness threshold. Nil
    means never. It is a setting, not an event: nothing replays it, and 8.2 records each person
    it forgets.
  - Only a tenant admin may change it, through `Operations::Tenants::UpdateRetentionPeriod`.
    An Org Graph editor may not. How long to keep a leaver is the organisation's
    data-protection decision, not a change to its structure.
  - `OrgLeaver.due_to_be_forgotten(tenant)` returns the person ids of the leavers whose
    period has ended, and nothing else. The leaving date is the latest `PersonLeft`'s, so a corrected date counts.
    For a person the HRIS stopped returning, it is the day the sync noticed. Someone who
    returns drops off the list. A leaver whose rehire has not started yet stays on it, since
    the sync writes nothing until they start, so 8.2 checks the HRIS before it erases anyone.
  - `org_graph/leavers` reads event types production already holds, so its first deploy sets
    `REBUILD_ON_DEPLOY=org_graph/leavers` to fill it.
- At the end of the period, or on request, the identifiers are erased from the `people`
  row and `PersonForgotten` is written.
- Only a person who has left can be forgotten. A request about someone still employed is
  refused: the HRIS is the source of their identifiers and the next sync would write them
  back. They are removed there first.
- Projections act on that event. The person renders as a former member. Positions, teams and
  past plans keep their history.
  - The row's name becomes "Former member" (story 8.3), and a check constraint holds every
    forgotten row to it. Read models join `people` for names rather than copying them, so every
    screen, export, MCP read and report shows the stand-in, a raw pluck included.
    `test/integration/forgotten_person_audit_test.rb` walks every MCP read to keep it so.
  - `org_graph/leavers` drops the person, so they leave the due list. The other Org Graph
    projections hold ids and no identifiers, so they keep their rows unchanged. The history
    projection (3.1) handles `PersonForgotten` from its first version.
  - Each person is forgotten in one transaction: the row, the tenant membership, the names
    stored notifications copied, and the event with its synchronous projections. A run that
    dies partway leaves each person forgotten or untouched, so no checkpoint is needed.
  - The tenant membership is kept, deactivated and unlinked from its login. The global login
    is untouched, since it can belong to other tenants.
- The schedule ships off. A tenant admin turns it on with the count a dry run gives, and
  forgetting one person on request stays off MCP. Operating it, the key and what a restore
  undoes: [org-graph-forgetting.md](../runbooks/org-graph-forgetting.md).
- Free text that names the person, in evidence, comments, feedback and alignment notes, is
  not erased until shreddable fields land ([#110](https://github.com/espaliahq/espalia/issues/110)).
- The sync must not undo it. An HRIS often keeps returning a person long after they
  leave, and a sync that upserts every row it is given would write the name back. The
  row keeps a keyed hash of the external id, enough to recognise the person and nothing
  to identify them by. The sync skips a matching row for as long as the HRIS
  shows the person as not employed. When it shows them employed again, the sync creates a
  new person with a new id, and moves the hash's match to that record so later syncs
  update it. The new record and the forgotten one are never linked.

Operational facts are retained. In a small organisation they can still point to one
person: the only principal designer in a team is identifiable without a name. We accept
that for operational history. Whether identifier erasure satisfies a given legal request
is for the organisation running Espalia to decide. Removing one person's stream entirely
can be added later, at the cost of gaps in history.

## How this answers Team Planning

| # | Answer |
|---|---|
| R1 | The existing person id. Identifiers stay in the `people` row. |
| R2 | The person stream, written by the sync. The sync must also bring in site and country, FTE and employment type, and start date, and any field a structure level names. |
| R3 | The structure stream, with its own history and succession, and membership events in the person stream. |
| R4 | The history projection. |
| R5 | A provider and a confirmation on every event. |
| R6 | The membership and unit commands, with an effective date and a source. |
| R7 | `PersonForgotten`. |

## Not in a first version

- Reasons for a change, and anything else sensitive.
- Mapping an HRIS value onto a unit Espalia already holds, by hand. A level the HRIS
  provides mirrors its field's values as they are. At a handover each unit's value is
  suggested by name and confirmed by a person, and what does not match is listed.
- Positions from an applicant tracking system, and pay from a pay integration.
- A full editing screen for structure.
- Suggesting succession. A direct edit that retires one unit and creates another records
  no link between them. The Org Graph never infers one. Later it can suggest a link from
  shared members, for someone to confirm.
