# Team Planning — data design

> Status: proposal. Nothing here is built. [The index](README.md) lists the companion
> designs, the mockups and the plan.
>
> Read [the module description](team-planning.md) first: it says what a planner
> can do. This page says how the data is held. It depends on two other designs:
> [the Org Graph](org-graph-design.md) and
> [shreddable event fields](shreddable-fields-design.md).

## The shape in one paragraph

A plan is one event-sourced aggregate with one stream. Scenarios live inside it. Every
change records an end state for one subject in one scenario. What a scenario looks like
is never stored: it is resolved by reading the Org Graph, then the plan's changes down the
scenario chain. The plan never contains the Org Graph. It holds a pointer to it.

## What Team Planning requires of the Org Graph

Planning cannot be built before these exist. They are numbered so the Org Graph's design can
answer each one, and so we can see the smallest record that unblocks planning.

| # | Requirement |
|---|---|
| R1 | A stable id per person. Identifiers (name, email) are held apart from events. |
| R2 | Roster facts with history: active or left with dates, title, level, manager, cost centre, country, FTE and employment type. |
| R3 | Units and membership: nested units in tenant-named levels, and a person's membership of a unit with an allocation. Units keep their identity through a rename or a move, and a split or merge can be stated. |
| R4 | Reading R2 and R3 as of a date, and listing what changed between two dates. |
| R5 | Provenance on every fact: which provider supplied it, and when it was last confirmed. |
| R6 | Applying a change to a fact Espalia holds, with an effective date and a reference to where the change came from. |
| R7 | Forgetting a person, announced as an event that projections can act on. |

Not required for a first version: reasons for a change, pay from an integration,
positions from an applicant tracking system, and mapping an HRIS team by hand onto a unit
Espalia already holds.

The budget is not asked of the Org Graph. See *The headcount budget*.

R4 is the expensive one. A plan stands on the Org Graph as of a date, and must be able
to say what moved since.

## The plan stream

`tenant-{id}/Plan-{plan_id}`, named through `EventStreamNaming` like every other stream.

Scenarios are entities inside the plan, not streams of their own. Forking, re-parenting
and removing a scenario are then checked in one aggregate, and one history covers the
whole plan.

### Scenarios as built

Story 3.1 ([#208](https://github.com/espaliahq/espalia/issues/208)) built the tree.

- The baseline is implicit. Its id is the plan's, it stands on the base date, and it has
  no period, no alternative and can't be removed.
- A `then` scenario starts the day after its parent ends, or on the base date after the
  baseline. It holds its own end, and `ScenarioPeriodSet` moves only that end.
- An `instead` scenario covers its parent's period exactly, so an alternative of an
  alternative covers the original's.
- A parent has at most one `then` step. A second next step is an alternative to the first.
- A move that would leave a later step ending before it starts is refused, and the
  refusal names that step.
- A scenario others fork from can't be removed. Ids are never reused.
- Scenario names are plain text in the event, as plan names are. Until
  [#209](https://github.com/espaliahq/espalia/issues/209) shreds them, the name parameter
  asks callers to leave people's names out.
- `team_planning_scenarios` holds one row per scenario, with the period the tree gives it.

### Events

Every change event has the same shape:

```ruby
{
  plan_id:,
  scenario_id:,
  subject:,     # what the change is about: a person, a position, a unit, a rule, a budget line
  state:,       # where the subject ends up; never a step from a previous state
  note:,        # why; shreddable under the plan key
  set_by:
}
```

| Group | Events |
|---|---|
| Lifecycle | `PlanCreated`, `PlanRenamed`, `PlanMemberAdded`, `PlanMemberRemoved`, `PlanDeleted` |
| Scenarios | `ScenarioForked` (parent, `then` or `instead`, period), `ScenarioDescribed`, `ScenarioPeriodSet`, `ScenarioSplit`, `ScenarioRemoved` |
| Structure | `UnitSet` (name, parent), `UnitRetired`, `UnitSuccessionSet` (which units carry on from which), `PositionSet`, `PositionClosed` |
| People | `AssignmentSet` (person, position or unit, allocation), `ReportingLineSet`, `DepartureSet` (person, linked position), `LevelSet` (person, level: a planned promotion) |
| Budget | `BudgetLineSet`, `BudgetLineCut`, `PositionFundingSet` (position draws on budget lines) |
| Plan data | `PlanDataSet` (subject, field, value) |
| Rules | `RuleSet` (configuration, capacity model, budget strictness, guardrail, assumption) |
| Clearing | `ChangeCleared` (scenario, subject, facet): the item follows its parent again |
| Pinning | `ChangePinned`: an inherited item made explicit as it stands |
| Undo | `ChangeUndone`, `ChangeRedone`, each naming the event it reverses |
| The Org Graph | `PlanRebased` (the date the plan now stands on) |
| Reality | `StepClosed`, `PlanApproved`, `ChangeRaised`, `ChangeApplied` |

Subjects the plan creates (a position, a unit, a placeholder hire, a budget line) get an id
minted by the plan. Subjects from the Org Graph are referred to by the Org Graph's id. A change
never refers to the content of its parent scenario. That is what lets the same change be
resolved over a different base.

### Propagation is a projection, never an event

Editing an ancestor appends one event to the stream. Nothing is written for its
descendants. A descendant shows the change because its state is resolved at read time:

1. The Org Graph, as of the plan's base date.
2. Tenant defaults, for configuration.
3. The plan's own data and rules.
4. Each scenario's changes, from the root of the chain down to the scenario on screen.

The last change for a subject and facet wins. A facet is the part of a subject one kind
of event sets: a person's assignment, their level and their reporting line are three
facets, so `LevelSet` never competes with `AssignmentSet`. "Rebase" is this resolution run over a new base, so
nothing has to be rewritten in storage. A descendant's explicit change survives an
ancestor's edit because it is later in the chain, not because anything protected it.

A change that no longer fits (it places someone in a unit an ancestor has retired) still
resolves. The projection marks it as needing attention.

### Rules

A rule is a setting a plan can change, such as a headcount cap or how strictly a budget
holds. Each kind is a `TeamPlanning::RuleKind`, listed in `TeamPlanning::RuleKinds::BUILT_IN`.
A kind names itself, gives a built-in default and checks a value. A value is always an
object. No kind ships yet: the first come with 5.2, 7.1 and 8.1.

`RuleSet` sets one rule for a subject: the plan's id for the whole plan, or a unit's id for
that unit and the units below it. Every rule is its own facet (`rule:<name>`), so two rules
on one subject both land. `Map#rule(name, unit_id:)` reads a rule in this order:

1. The unit, then each unit above it on the scenario's map.
2. The plan-wide value.
3. The tenant's default, set by an admin with `tenants_set_planning_rule`.
4. The kind's built-in default.

A retired unit's rules drop out with it. Tenant defaults are read as they stand now, not
as of the base date, since they are configuration and not facts about the organisation.

A rule's value may one day be sensitive: an on-cost rate, a guardrail on pay. So a refusal
names what is wrong and never repeats the value. A kind declares `shreddable?`, and until
[#213](https://github.com/espaliahq/espalia/issues/213) brings shredding, a kind that says
yes is refused at registration.

A scenario has two paths from the root, and the code keeps them apart:

- **The resolution chain** (`PlanAggregate#resolution_chain`) is every scenario whose
  changes it resolves through. An alternative follows its parent, so it starts as the
  parent plus its own differences, and its own changes win.
- **The timeline path** (`PlanAggregate#timeline_path`) is the steps as the timeline lays
  them out. An alternative takes its parent's place, sharing its period and column.

An alternative that wants what its parent's parent had sets that end state itself. A
one-step "follow the parent's parent again" is `ChangeCleared` (3.9).

In code, each change kind subclasses `TeamPlanning::Events::Change`, names its facet and
says how its end state lands on a map. `TeamPlanning::Resolution` reads
`TeamPlanning::Baseline#structure`, applies the winning change for each subject and facet
along the resolution chain, and joins names last.

### Undo

Undo and redo are events that point at the event they reverse. The stream is never
edited. A scenario's history, with who made each change, is the stream filtered by
scenario.

### Two people editing at once

End-state changes to different subjects, or to different facets of one, commute. The
repository holds the plan's lock from load to store, so a second editor's change loads
only after the first has landed: no version conflict reaches the aggregate, and there is
nothing to retry. Two changes to the same subject and facet are a real conflict: the last
write wins and both stay in the history.

## The base pointer

A plan stands on the Org Graph as of a date. `PlanCreated` sets it and `PlanRebased`
moves it. Planning asks the Org Graph two questions and no others:

- What was true on this date, as known at the end of the day before? (R4)
- What has the Org Graph learned since that day? (R4) This is the drift report.

Reading the base as known the day before closes it: edits made later on the base date
arrive as drift rather than moving the plan under its users. The plan stores the date,
never a copy of the roster.

### When the Org Graph changes twice on the base date

Two things can happen on one date, and the plan treats them differently:

- **Changes taking effect that day, recorded before it.** A move scheduled for the base
  date is part of the base. If two such changes set one fact, the later one recorded
  stands, as `AsOf` reads it.
- **Changes the Org Graph learns that day.** Neither is in the base. They arrive as
  drift, and `ChangesBetween` reports one net change per fact. Two edits to one fact
  make one drift row, with the later value, and the earlier value is not shown.

A plan whose base date is still to come reads what the Org Graph knows now, until the
day before its base date has passed. Until then its base moves as edits land.

### The baseline reader

`TeamPlanning::Baseline` reads the root scenario, which changes nothing yet, over
`OrgGraph::AsOf` on the base date, known at the end of the day before. It is refused to
anyone `PlanPolicy#show?` refuses. It returns a `Map`:

- **Units**: the live units, with parent, level and owners.
- **People**: everyone employed that day, with their facts and each membership's unit,
  allocation and role.
- **Unassigned**: the people in no live unit.

`structure` returns the map by id with no names, so scenario resolution (3.2) can apply
a plan's changes before anything is named. `call` joins the names last from the
`people` table, for the people, their managers and the units' owners, so anyone forgotten
reads "Former member". The forgotten-person audit walks it.

## Status is derived, never stored

Each planned change is compared with the Org Graph as it stands now:

| Status | Meaning |
|---|---|
| Done | The Org Graph matches the change. |
| Pending | The Org Graph does not match yet. |
| Raised | Pending, and someone has recorded that the upstream change was asked for. |
| Conflicting | The Org Graph went somewhere else. |

Only `Raised` rests on an event (`ChangeRaised`). The rest are read by comparison, so
they can never disagree with the Org Graph.

## Plan-held data

Values a plan holds on top of the Org Graph (a pasted salary, a corrected level, a hire not
in the HRIS yet) are `PlanDataSet` events. A value about a named person, such as their
pay or a corrected level, is shreddable under that person's key in the plan. Every other
value, every note and every scenario description are shreddable under the plan's key.
Deleting the plan deletes every key it holds. The events remain and still say that
something was set; what it was is unreadable at once, and gone for good once the backups
taken before the deletion have expired.

Two consequences of [the aggregate guard](shreddable-fields-design.md):

- The aggregate cannot decide anything on a plan-held value. Checks that need the value,
  such as a salary outside its band, are projections. That matches the rule that
  guardrails are shown and not enforced.
- "Unchanged, so do nothing" cannot be checked in the aggregate for these fields. The
  Operation checks it against a projection.

## The headcount budget

The budget stays in the plan. A budget line approved for a person already employed is close to that
person's pay, so it belongs with the plan's other sensitive values, under the plan's key
and deleted with it.

- **Headcount budget only.** A budget line is permission to spend on people: a period, an
  amount or a head count or both, and optionally the role, level, location and cost
  centre it was approved for. Cost centre is the label the Org Graph carries for a
  person, used for grouping. Accounts, ledger codes and every other financial or
  accounting identifier are out of scope.
- **Budget lines are plan data.** `BudgetLineSet` and `BudgetLineCut` in a plan's root scenario
  are its approved budget. A descendant changes them like anything else. The amount is
  shreddable under the plan's key.
- **On-cost models.** What a position costs beyond base pay is calculated by an on-cost
  model: a flat rate, rates by country, or itemised components. Models are chosen and
  set like capacity models, with a tenant default that a plan or scenario can change.
- **The basis is stated.** A budget is either inclusive of on-costs or base pay only.
  The basis is a rule of the scenario. Positions are measured on the same basis as the
  budget they draw on, so the four numbers always compare like with like, and every
  total says which basis it is on.

### Which budget line a position draws on

Funding is derived by default, in two steps. Neither writes an event.

**Position to cost centre.** The first of these that applies:

1. A cost centre set on the position. `PositionSet` carries an optional label.
2. For a filled position, the occupant's cost centre in the Org Graph, or the plan's change
   to it.
3. For an open position or a placeholder, the cost centre rules.

Cost centre rules are a kind of `RuleSet`: an ordered list of a matcher and a label, where
the first match wins. A matcher names a unit (and so its subtree), a role or role family
from the framework, or a unit and a role together. The list is ordered because
organisations differ on whether the unit or the role decides. Rules start from the
tenant default, and a plan or scenario can change them.

**Cost centre to budget line.** The most specific budget line that matches the position's cost centre and
period, and whichever of role, level and location the budget line states. `PositionFundingSet` is
the exception only: a position funded from another centre, or split across budget lines. A position no
budget line matches is unfunded.

The projection records how each position's cost centre was reached (set here, from the Org
Graph, by which rule) and reports three conditions as checks:

- **Mismatch.** A filled position whose occupant's cost centre differs from what the rules
  give the position. The known value is used and the mismatch is always flagged. It is
  resolved by planning the cost centre change, which joins the change list to be raised
  upstream. The rules never move a person's cost on their own.
- **Unplaced.** An open position no rule matches. It draws on no budget line. This is a warning
  while drafting, and a guardrail a tenant can make binding at approval.
- **Ambiguous.** Two budget lines match a position equally well. Nothing is picked silently.

A tenant's approved budget reaches a new plan as a default, the way configuration does.
If budget later moves to a provider, the budget lines keep their shape and a plan keeps only
its changes.

## Actual, planned and forecast

Every figure has one of three sources, and the stored form follows from which.

| Source | Stored as | Changes when |
|---|---|---|
| Actual | Nothing in the plan. Read from the Org Graph as of the base date. | The base moves (`PlanRebased`). |
| Planned | An event in the plan stream. | Someone edits the scenario. |
| Forecast | Nothing. Calculated by a read model from the plan's assumptions. | An assumption changes, or the base moves. |

Rules that follow:

- **An assumption is a `RuleSet`.** It has a tenant default and resolves down the
  scenario chain like any other rule, and can be set for one unit.
- **A forecast is an adjustment, never a subject.** It has no id, no person and no
  position. It is a row per unit and step in cost, capacity and the headcount walk. It
  cannot be pinned, cleared or undone, because nothing was written.
- **Only planned changes are approved.** The pinned point covers events. The change list
  is built from events. A forecast can appear in neither.
- **Planned removes from forecast.** A read model leaves out of a forecast anyone a
  planned change already covers: a person with a `DepartureSet` is not in expected
  attrition, and a person with a `LevelSet` is not in forecast promotions.
- **Read models keep the three apart** in every total, so a total can state its make-up
  and a closed step can compare its forecast with what happened.

The assumptions in a first version:

| Assumption | Forecasts | Fed by |
|---|---|---|
| Attrition rate | Departures per unit and step, with backfills open for the time to hire. | The rate. |
| Promotion timing | Promotions per unit, level and step, with their cost and capacity. | Promotion readiness (A2). |
| Pay increase | Added pay per unit and step: a flat rate, or movement toward each person's place in band. | Ratings against level (A1). |
| Time to hire | A start date for an open position that has none. | The tenant's figure. |
| Ramp | A new hire's capacity in their first steps. A parameter of the capacity model. | The capacity model. |

What stays planned: `PositionSet` carries a hiring status and a target start date,
plan-held until a hiring system is the provider of open positions. `LevelSet` is a
planned promotion for a named person. Its level is shreddable under that person's key
in the plan, because it is the plan's statement about them. A pay figure typed into the plan is a
`PlanDataSet`, as before.

Forecast promotions and pay increases draw on a pool: a budget line approved for
promotions and increases, matched by cost centre and period like any other.

Two of these forecasts add a dependency this module did not have before.

| # | Required of assessments |
|---|---|
| A1 | For a person on a date, as known at the end of the day before: where their ratings place them against their level, in a form that maps to a place in a pay band. |
| A2 | For a person on a date, as known at the end of the day before: promotion readiness for the next level. |
| A3 | Whether a given viewer may open that person's assessment. |
| A4 | The assessment changes recorded between two dates, for the drift report. |

The forecast is served as totals under the cohort rule. A3 gates the per-person
breakdown: the Operation returns it only for people whose assessments the viewer may
open, so the web and an MCP client get the same answer.

Assessments are read as of the plan's base date, like every other fact. A new
assessment cycle shows up as drift and takes effect on rebase.

## Approval and carrying a plan out

Approval is the one process this module owns.

- `PlanApproved` names a scenario and pins a point in the plan stream. What was
  approved is exactly the changes up to that point. A later edit is a new difference
  that needs its own approval.
- A scenario is approved whole. To approve part of one, split it first. See *Splitting a
  scenario*.
- Tenant guardrails are binding at approval and nowhere earlier.
- **Facts Espalia holds** are applied to the Org Graph on approval (R6). Each is recorded as
  `ChangeApplied`. So approving a scenario that changes any of them needs both
  permissions: to approve, and to apply changes to the Org Graph. Without the second the
  approval is refused whole. It is never recorded with its changes left unapplied.
  `PlanApproved`, the Org Graph's events and each `ChangeApplied` are one transaction.
  The plan stream and the Org Graph's streams share an event store, so they commit
  together or not at all. A change the Org Graph rejects fails the whole approval.
- **Facts another system holds** are not written by Espalia. Espalia is the source for
  the implementation: an Operation serves the approved change list, and an agent or a
  person raises each change upstream with their own authority there.

The change list is served only for an approved point, so a draft cannot be carried
out. Each entry has a stable id, its subject, its end state, what it depends on and its
status. One small write goes with it: `ChangeRaised`, with the upstream reference. It
shows a planner what is in flight.

`ChangeRaised` alone does not make a second run safe. An agent can raise a change and
fail before recording it, and two agents can pick up the same entry. The entry's stable
id is the guard. The agent sends it with the upstream request, as an idempotency key or
in the request's text, and looks for it upstream before raising. Looking first
is not atomic: two agents can both look, both find nothing, and both raise. Only an
idempotency key the other system enforces closes that. Without one, a duplicate request
is possible, and a person there has to catch it and withdraw one. If that proves common,
the fix is a claim on the entry in the plan stream, where only one writer can win.
Espalia's own state stays right either way, because done is read from the Org Graph.

Done is still decided by the Org Graph. Nothing the agent reports marks a change done.

## Splitting a scenario

In practice part of a scenario is agreed and the rest is not. `ScenarioSplit` divides one
scenario into two:

```
before:   parent ── S ── descendants
after:    parent ── S₁ (the agreed part) ── S (the rest) ── descendants
```

- The event names the changes that move into the new scenario. The original keeps its
  id, the remaining changes and all its descendants.
- **Nothing anyone sees changes.** The moved changes are now inherited by the original
  where before it set them itself, so it and every descendant resolve to exactly what
  they did. The split only draws a line through the scenario.
- A change moves with every earlier change it overwrites. If the scenario set a level to
  3 and later to 4, moving only the 4 would leave the 3 behind to win. The earlier
  changes for the same subject and facet go across with it.
- The two parts cover the same period. This is a third relation beside `then` and
  `instead`: the rest sits on top of the agreed part. The timeline shows them as one
  column with the agreed part marked.
- The agreed part must stand without the rest. A change cannot move across if it depends
  on one that stays, such as a person placed in a unit the rest creates. The split says
  which changes block it.
- The agreed part can then be approved and carried out. As its changes are done they leave
  the difference, and the rest is what remains to be argued.

## Closing a step

`StepClosed` records the date a step's period ended. From then on:

- The next step resolves over the Org Graph, not over what the closed step planned.
- Changes still pending in the closed step are shown in the next step as carried over.
  This is derived: no event copies them.
- The closed step is read as planned against actual, using the Org Graph as of its end (R4).
- Alternatives to the closed step that were not taken are kept with it and no longer
  offered.

## Projections

| Projection | Serves |
|---|---|
| Scenario state | The resolved map for one scenario: units, positions, assignments, reporting. |
| Overrides | Everything a scenario sets, what it replaced, and where that came from. |
| Cost and budget | Approved, funded, remaining and unfunded, per unit and cost centre. |
| Capacity | Per model, per unit, with each person's working. |
| Capability profile | Per unit and per position, under the existing cohort rule. |
| Timeline | One path through the scenario tree, with lanes and moves. |
| Headcount walk | Per step and unit: opening, hires, known and expected departures, transfers, closing. Drawn as a lane of the timeline. |
| Checks | Every warning, with guardrail checks marked. |
| Change list | The approved changes with their derived status. |

Projections must rebuild with every key forgotten. That rebuild is how a deleted plan's
values leave the read models.

## Permissions

- A plan is private to its members, each an editor or a viewer.
- Seeing pay is a separate permission. Without it a member sees band midpoints.
- Approving, and applying changes to the Org Graph, are each their own permission.
- Every read and write is an Operation, so the web and an MCP client pass the same
  checks.

## Kept possible, not built

**Overlays.** An alternative that can be switched on over the main line and carried
through every later step, so the later steps are not built twice. Nothing is built for it
yet. Three properties of the events keep it possible, and must not be given up:

- A change records an end state for one subject and never refers to the content of its
  parent.
- Subjects a plan creates have ids that are unique in the plan, not in a scenario. The
  same position is the same position in every scenario that inherits it.
- A scenario's parent is a reference in an event, not a place in a stored tree. A
  scenario can later be resolved over a different base.

## Decided, with a known cost

**Erasure inside a live plan.** When the Org Graph forgets a person, a handler on
`PersonForgotten` destroys that person's key in every plan at once. Every value a plan
held about them, such as their pay, a corrected level or a planned promotion, becomes
unreadable. They stay in each plan's history as a former member with no identity.

One thing can still name them: a note. A note is free text under the plan's key, so one
that mentions the person stays readable to the plan's members until the plan is
deleted. Deleting the plan is the remedy when that is not acceptable.
