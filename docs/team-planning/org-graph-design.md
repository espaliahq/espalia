# Org Graph — design

> Status: proposal. Nothing here is built. [The index](README.md) lists the companion
> designs, the mockups and the plan.

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
| `TitleChanged`, `LevelChanged` | The HRIS's own title and level, before any mapping to a framework. |
| `ManagerChanged` | The new manager's id, or none. |
| `CostCentreChanged`, `SiteChanged` | The cost centre as the HRIS names it. |
| `EmploymentChanged` | FTE and type. |
| `MembershipSet`, `MembershipEnded` | A unit, an allocation, and the role played there. |
| `FactConfirmed` | That a fact Espalia holds is still true, and who said so. |
| `PersonForgotten` | That the identifiers have been erased. |

Every event carries the provider that supplied the fact, the date it took effect, and,
where it came from a plan, a reference to the plan's change.

### One structure stream per tenant

`tenant-{id}/OrgStructure`

| Event | Records |
|---|---|
| `TaxonomyDefined` | The tenant's names for its levels. Redefining it is a change like any other. |
| `UnitCreated`, `UnitRenamed`, `UnitMoved`, `UnitRetired` | A unit's life. |
| `UnitSucceeded` | That one or more units carry on from one or more others: a split, a merge, a replacement. |
| `UnitOwnerAdded`, `UnitOwnerRemoved` | Who may edit the unit. |

Units carry their provider too: a unit mirrored from an HRIS team is read-only in
Espalia, and units Espalia holds can hang beneath it. A mirrored unit also carries the
provider's own reference for it, so a rename in the HRIS is recognised as a rename. See
[Which HRIS field a fact comes from](#which-hris-field-a-fact-comes-from).

Membership is a fact about a person, so it lives in the person's stream. A unit's
members are a projection.

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

**Trust, then verify.** No change waits for anyone's acceptance. A manager places their
report in a squad and it is so. What keeps that honest is visibility: every change is an
event with who made it and when, and the Org Graph shows an activity sidebar like the
one a framework has. A unit's owners see what changed in their unit and can change it
back.

Ownership is always stated. It is never derived from reporting lines or from a role in
the unit, because a cross-functional team has no single line to derive it from. When a
unit's last owner leaves, the unit is flagged and inherits its parent's owners until
someone is named.

### What happens to `people`

The identifier columns stay as they are: mutable, written by the sync, and the only place
a name or an email is stored. The other columns become a projection of the person's
stream.

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

A person who disappears from the HRIS gets `PersonLeft`. Their memberships are ended by a
handler, with the leaving date. A new person appears with no membership. No position is
created for anyone automatically.

The first sync after this ships writes `PersonRecorded` for everyone. Nothing earlier can
be reconstructed.

## Reading as of an instant (R4)

Each fact has two times: when it took effect, and when the Org Graph learned it. A history
projection keeps one row per fact, per period of validity, per time learned. A correction
adds a row with a later learned time. It never overwrites the row it corrects, or the Org
Graph could no longer say what it knew before. From it:

- `as_of(instant)` gives the roster and structure the Org Graph knew at that instant.
- `changes_between(a, b)` lists the facts that differ.

"As of" is by the time the Org Graph learned a fact. A plan pinned to last Tuesday sees what
was known last Tuesday, even if a backdated correction arrived since. The correction
shows up as drift.

## Applying a change (R6)

Facts Espalia holds change in two ways. Both issue the same commands.

- **From a plan.** Approval applies the plan's changes, each tagged with the change it
  came from.
- **Directly.** Someone permitted edits the structure. A first version needs little
  here, because a first plan applied whole creates the structure.

Either way the change carries an effective date, so a move can be recorded as having
happened on the first of the month.

Facts another provider holds cannot be changed here. They change when the sync says so.

## Providers and provenance (R5)

Each kind of fact names its provider, per tenant. For structure the setting is per
taxonomy level, so an HRIS can own departments and teams while Espalia holds the squads
beneath them.

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
  compared as above, and the disagreements are listed.

A list field keeps a unit through a rename. Its values have ids of their own, so the
unit's external reference is the value's id, and a new label is `UnitRenamed`: the
history reads "was X". A free-text field has only its text. A renamed value there looks
like one unit emptying and another appearing, and the Org Graph does not infer a link.
Someone can state the succession. The screen says which kind each field is.

#### What the sync needs for this

The HiBob adapter is most of the way there, and the gaps are small.

- It can already read the field catalogue and the named lists. Nothing calls either yet.
- It requests a fixed set of fields, with department the only structural one. One extra
  field per tenant is already supported, for the level. The requested set becomes the
  fields the tenant's mapping names.
- The level field is set by pasting its raw id. The picker replaces that.
- It asks for both the stored value and the display text, and keeps only the text. It
  needs to keep the value's id beside it.

One thing to confirm per adapter before relying on it: that the stored value of a list
field is a stable id, and stays the same when the label changes.

Open question: a unit whose people sit under two different units at the level above.
The likely answer is to list it for someone to resolve, as a disagreement is.

## Forgetting a person (R7)

- A tenant sets a retention period for people who have left. The default is seven years from the
  leaving date. "Never" is allowed.
- At the end of the period, or on request, the identifiers are erased from the `people`
  row and `PersonForgotten` is written.
- Projections act on that event. The person renders as a former member. Positions, teams and
  past plans keep their history.
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
  provides mirrors its field's values as they are. At a handover the two are matched by
  name, and what does not match is listed.
- Positions from an applicant tracking system, and pay from a pay integration.
- A full editing screen for structure.
- Suggesting succession. A direct edit that retires one unit and creates another records
  no link between them. The Org Graph never infers one. Later it can suggest a link from
  shared members, for someone to confirm.
