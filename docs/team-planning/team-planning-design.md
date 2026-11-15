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
  note:,        # why; shreddable under the subject's key: a person's in the plan, else the plan's
  set_by:
}
```

| Group | Events |
|---|---|
| Lifecycle | `PlanCreated`, `PlanRenamed`, `PlanMemberAdded`, `PlanMemberRemoved`, `PlanDeleted` |
| Scenarios | `ScenarioForked` (parent, `then` or `instead`, period), `ScenarioRenamed`, `ScenarioDescribed`, `ScenarioPeriodSet`, `ScenarioSplit`, `ScenarioRemoved` |
| Structure | `UnitSet` (name, parent), `UnitRetired`, `UnitSuccessionSet` (which units carry on from which), `PositionSet`, `PositionClosed` |
| People | `AssignmentSet` (person, position or unit, allocation), `ReportingLineSet` (person, a person or a position), `DepartureSet` (person, linked position, optional leaving date), `DepartureWithdrawn`, `LevelSet` (person, level: a planned promotion) |
| Budget | `BudgetLineSet`, `BudgetLineCut`, `PositionFundingSet` (position draws on budget lines) |
| Plan data | `PlanDataSet` (person, field, value), `PlaceholderSet` (a hire the HRIS doesn't know: label, level, FTE) |
| Rules | `RuleSet` (configuration, capacity model, budget strictness, guardrail, assumption) |
| Clearing | `ChangeCleared` (scenario, subject, facet): the item follows its parent again |
| Pinning | `ChangePinned`: an inherited item made explicit as it stands |
| Undo | `ChangeUndone`, `ChangeRedone`, each naming the event it reverses |
| Notes | `ChangeNoted`: a change's or pin's note written, rewritten or cleared |
| The Org Graph | `PlanRebased` (the date the plan now stands on, the one before, and the conflicts it carries) |
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
facets, so `LevelSet` never competes with `AssignmentSet`. Two kinds may share a facet on
purpose: `PositionSet` and `PositionClosed` both set `position`, so a later set reopens a
closed position. "Rebase" is this resolution run over a new base, so
nothing has to be rewritten in storage. A descendant's explicit change survives an
ancestor's edit because it is later in the chain, not because anything protected it.

A change that no longer fits (it places someone in a unit an ancestor has retired) still
resolves. The projection marks it as needing attention.

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

### The timeline as built

`TeamPlanning::Timeline` (the `team_planning_timeline` tool) reads one timeline path and
stores nothing ([#289](https://github.com/espaliahq/espalia/issues/289)). It resolves each
step as the map does, then lays the steps out as columns. The Timeline tab
([#298](https://github.com/espaliahq/espalia/issues/298)) draws what it returns and decides
none of these rules:

- **Blocks.** A unit is one block across the columns it lives in, so a rename changes the
  label, not the block. A unit that succeeds exactly one other continues that block. A split
  or a merge starts new blocks that name the ones they carry on from.
- **Lanes.** A lane belongs to a person and lasts while they are on the map, placed or not.
  Someone in two places at once has one lane with two bars, and that is no move.
- **Moves.** A move names the units a person left and joined between two columns. Carrying
  on into a unit's successor in the same block is no move. Placed in
  no live unit reads as Unassigned, so a lane never vanishes because its person lost a place.
- **Backfills.** A leaver's lane records the step they leave in, and the position that
  backfills them carries on in it, naming who it replaces. A new position gets a lane of its
  own, and the first person to fill it takes that lane, so a seat and its hire read as one head.
  A seat shared by two hires gives its lane to one of them. A backfill shared by two leavers
  runs in the lane of the first, the one its `replaces_id` names.
- **Order.** Blocks come in the order they first appear. Lanes come by the column they first
  appear in, people before positions, then by name and id.
- **Names.** Lanes and blocks carry ids, and names come from the map's own lookup, so a
  forgotten person keeps their lane under Person::FORMER_MEMBER.

The baseline is read once and every step resolves over it, so each column sees the same Org
Graph and the read costs one Org Graph query whatever the path's length.

The tab shows one path at a time. With no scenario named, it follows the first `then` at
each step to a leaf, and the page says which path it shows and how many others run through
the plan. Each step lists its alternatives as "or instead" links, and the last step its
`then` steps, so a viewer switches path by following one. A wide screen draws a grid: a
column per step, a heading per block, and a row per lane, with each bar spanning the steps
it holds. A phone shows one step at a time, picked from a row of steps that marks the
current one. Since the neighbouring steps are out of sight there, each bar says where its
person came from when they arrive and where they go when they leave. A path with nobody on
it still shows its steps, so its alternatives stay in reach.

An editor moves people from the tab too ([#309](https://github.com/espaliahq/espalia/issues/309)).
Dragging a person's bar onto another block in a column moves them in that column's step, and
a drop outside the bar's own steps is refused. Each bar also has a "Move…" button, a menu of
its steps when it spans several, so the keyboard and a phone reach the same form. On a phone
it moves the person in the step shown. The form is the map's, one per step, and saves
through `MovePlace`, then returns to the same step of the timeline. Today has no handles,
and a viewer sees none. Moving a change a step earlier or later is the next part of 9.3.

### Unit changes as built

`UnitSet` carries a unit's whole end state: its name, its parent and its level. It creates a
unit (the plan mints the id), renames one or moves one, and a later `UnitSet` brings a
retired unit back. `UnitRetired` shares its facet, `unit`, so whichever of the two comes
later wins. Since winning drops any earlier `UnitSet`, a retirement carries the unit as it
stood, so a unit the plan created, or renamed, retires as the plan had it. A unit's level never changes, as in the Org Graph: a unit at a new level is a new
unit with a succession.

`UnitSuccessionSet` is its own subject, with the facet `succession`. It names which units
carry on from which: one predecessor and several successors is a split, several and one is a
merge. `team_planning_set_unit_succession` retires each live predecessor in the same write,
as the Org Graph's own succession does. People stay where they are until an assignment moves
them.

The checks the Org Graph makes run in the operations, under the plan's lock, against the
scenario as it then resolves: the level is in the taxonomy and below the parent's, the parent
is live, no unit moves beneath itself, no unit retires with live sub-units, and no succession
loops back. A rename or move fills what the caller leaves out from that same resolve, so it
can't undo another editor's change. Only an ancestor's later edit can still break the checks;
the change resolves anyway, and 3.8 marks it. The unit tools write through
`CommandHandler#set_changes`, whose block returns the changes, since a succession lands with
the retirements it implies.

### Positions as built

`PositionSet` and `PositionClosed` share the facet `position`, so the later one wins and a
later `PositionSet` reopens a closed position. The plan mints a position's id. Its
`level_id` is the framework level that pay bands key on, so cost prices it with no
mapping, and the write checks that the level belongs to the role. `basis` is `backfill`,
which is committed budget, or `new`, which is planned; the map reads it as the position's
budget. A position's unit is not checked at write: a position in a retired unit still
resolves, and 3.8 marks it. The baseline has no positions, so every one starts in a plan.

### Assignments as built

`AssignmentSet` ([#229](https://github.com/espaliahq/espalia/issues/229)) has the facet
`assignment`, and its subject is a person. It holds the person's whole placement list:
each placement is in a position or a unit, never both, with an allocation above 0 and at
most 1 and an optional role. An empty list leaves the person unassigned. A child scenario
that changes one placement owns the whole list from then on, so a later edit to the
parent's list no longer reaches it.

- **Totals are read, not refused.** A person's `allocation_total` may pass 1, and 4.6
  flags it. A total is `nil`, which means unknown, when the HRIS gave a place no
  allocation. A check must not read unknown as under-allocated.
- **Unassigned is derived.** After the changes apply, `Map#settled` gives each position
  placement its position's unit, then lists everyone in no live unit as unassigned. A
  placement in a closed position keeps its `position_id` with no unit, and a placement in
  a unit gone from the map counts for nothing.
- **Open FTE** is a position's FTE less each occupant's allocation times their FTE, an
  unknown FTE counting as full time. It goes below 0 when a position is overfilled.
- **A person not on the map is never placed, but never silently.** The map lists them in
  `unresolved` with `why`: "joined after the base date", which updating the plan to today
  (4.2) fixes, or "has left", for a leaver by the base date or a forgotten person. 3.8
  marks them and the changes tab shows them.

### Reporting lines as built

`ReportingLineSet` ([#256](https://github.com/espaliahq/espalia/issues/256)) has the facet
`reporting_line`, and its subject is a person. Its end state points at a person
(`manager_id`) or at a position (`manager_position_id`), never both, or at neither for no
manager.

- **A graph of its own.** The baseline line is the Org Graph's manager fact. Lines are never
  read from units, so placing someone never moves their line.
- **A manager being hired.** A team whose manager is being hired reports to the open manager
  position, so it isn't credited to whoever the HRIS still lists. `Map#reports_of(id)` gives
  the people pointed at a person or a position: for a vacant seat, the span 7.2 charges it for.
- **Loops.** The write refuses a line that closes a loop in the scenario as it resolves then.
  An ancestor's later edit can still make one, so `Map#managers_above` stops at a repeat and
  4.6 marks it. It also stops at a position, which has no line of its own.
- **Fit is read.** A line to a closed position or to someone who has left still resolves.

### Departures as built

`DepartureSet` ([#256](https://github.com/espaliahq/espalia/issues/256)) has the facet
`departure`, and its subject is a person. It names the backfill position, or none when the
seat isn't backfilled, and the step the person leaves in. `DepartureWithdrawn` shares the
facet, so a later step or an alternative can have the person stay.

- **Leaving, then gone.** In the step that sets the departure, and in its alternatives, the
  person stays on the map marked as leaving. In the steps after it they are in the map's
  `departed`, out of the people, Unassigned and every total. `Resolution` gives the map the
  step's scenario ids, `apply_to` only marks the person, and `Map#settled` decides.
- **The step is stored.** A pin replays a change under the pinning scenario, so the end state
  names the step the person leaves in, and a pin in a later step keeps them gone.
- **The backfill.** The leaver never counts as filling it. The link lives only on the
  departure, so withdrawing, clearing or undoing it drops the link. A position reads as a
  backfill for the people whose departures name it, through `Map#backfills`, and as a
  backfill for nobody when none does.
- **Planned, not Org Graph leavers.** Someone the Org Graph has leave by the base date is off
  the map from the start, and the plan shows where it still places them (decision 6 in the
  plan). A departure is the plan's own statement.
- **A leaving date is optional.** `leaves_on` names their last day, within the step's
  period, and cost splits the step there: the leaver costs up to it, the backfill from the
  day after. Without one the step is the date, so the leaver costs nothing in it and the
  backfill carries the whole step. A departure set before dates existed carries no
  `leaves_on` and reads the same way. The baseline has no period, so a departure there
  takes no date.

### Needing attention as built

A write refuses only a malformed change. Fit is read, never refused
([#257](https://github.com/espaliahq/espalia/issues/257)). `TeamPlanning::Attention` walks a
resolved scenario and lists what no longer fits. `Attention.for` runs it on the settled
map and the changes that won, and nothing is stored. Each item has the subject and facet, a
reason a planner can read, and the change it belongs to: the later to land of the subject's own
winning change and the change that broke it, such as its unit's `UnitRetired`.

It marks a placement in a closed position, or in a retired unit or one gone from the scenario;
a position in such a unit, or overfilled; a unit under a retired parent; anyone in
`unresolved`; and a succession that lost a predecessor or whose successor is no longer live. A
position in a retired unit is the position's item, not each occupant's. `team_planning_attention`
reads it, and the changes tab (4.4) and the checks tab (4.7) will too.

It also checks each person (4.6):

- **Allocation.** Someone with no place at all is placed nowhere. A total above 100% is
  over-allocated, and one below is under-allocated. An unknown total is neither. Someone placed
  only in a gone unit or a closed position already has that item, so they are not also placed
  nowhere.
- **Since left.** Someone the scenario still has, with no planned departure, whom the Org Graph
  has had leave by today, a UTC day. They are placed but left, or, with no place, left. Either
  way that is their only allocation item. `Attention.for` reads them from
  `org_leavers`, since the base map can't know.
- **Manager.** A contributor with no manager, though not the head of the tree, who owns a unit
  with no parent. A manager, or a manager's position, no longer in the scenario. A manager who
  has since left. A manager who shares no unit with them: a manager shares one by being in or
  owning one of the person's units or the unit above it, so a lead reporting to the owner of the
  group around their team is not marked. A position in a gone unit is the position's item, not
  its reports'. These items have the facet `reporting_line`, and name the person's own change or
  their manager's, whichever landed last.

### Adding a change kind

Several lanes add kinds at once, so each adds one the same way. `PositionSet`
([#228](https://github.com/espaliahq/espalia/issues/228)) is the worked example.

1. **The kind.** Subclass `TeamPlanning::Events::Change` in
   `app/contexts/team_planning/events/`. Name its `facet`. Give it `end_state`, which
   checks the kind's own fields and returns them as stored; it raises `TeamPlanning::Error`
   with a sentence a planner can read. Give it `apply_to(map, data)`, which must not depend
   on another kind having landed. The kind's fields may not reuse `Change::FIELDS`.
   If the Org Graph holds its facet, also give it `subject_moved_by(change)`, naming the
   subject an Org Graph change moves, and `read_from(map, subject_id:, facet:)`, reading
   its end state back off a map. Without the first it meets no drift; without both it has
   no status, unless the Org Graph holds the subject under an id of its own and the kind
   overrides `read_org_graph` to find it, as a succession does (`Change.tracked?`). Test both in the drift and status tests, as their test-only kinds do.
2. **No registration.** `ChangeAwareApplyStrategy` routes every subclass to the aggregate,
   and `Resolution` applies whatever wins. Don't edit the aggregate, the strategy or the
   resolver.
3. **The map.** If the kind adds something the map doesn't hold, add it to
   `TeamPlanning::Baseline::Map` with an empty default in `Baseline#structure`, and join
   any names it needs in `Baseline#named`, never in `apply_to`. Anything derived from
   several kinds, such as who is unassigned, belongs in `Map#settled`, which `Resolution`
   runs once every change has applied. If a later change elsewhere can leave the kind's end
   state standing on something gone, add a check to `TeamPlanning::Attention` rather than
   refusing the write.
4. **The write.** An operation in `app/operations/operations/team_planning/` that includes
   `ChangeWrite` and calls `set_change!`. Put the checks the aggregate can't make, such as
   whether a framework role exists, in the block you pass it, since the aggregate reads no
   projection. The block runs under the plan's lock, after the editor check, so an outsider
   gets "No such plan" first and no check races another edit.
5. **The read.** Extend a scenario read, or add one through `PlanRead`, reading
   `Resolution#call`.
6. **The tool's shared files.** Merge main first. Run
   `UPDATE_SNAPSHOTS=1 bin/rails test test/mcp/tool_registry_snapshot_test.rb` and commit
   only your tools' files under `test/mcp/tool_snapshots/`; never edit the test. Give each
   read tool its own `test/integration/forgotten_person_audit/<tool>.rb`, a
   `ForgottenPersonAudit.walk` with its params, or `ForgottenPersonAudit.exempt` with a
   reason when it can't show a person. Add any new parameter to `params_for` in
   `test/integration/team_planning_privacy_test.rb`, which walks every Team Planning tool
   as an outsider. Put the tool's notes in its class comment; `bin/rails mcp:tools` lists it.
7. **The tests.** The kind's `end_state` refusals beside it in
   `test/contexts/team_planning/events/`. In `test/operations/team_planning/`, through the
   operations: a change reaching the steps after its scenario, an alternative overriding
   its parent, the outsider and viewer refusals, and tenant isolation.

### Rules

A rule is a setting a plan can change, such as a headcount cap or how strictly a budget
holds. Each kind is a `TeamPlanning::RuleKind`, listed in `TeamPlanning::RuleKinds::BUILT_IN`.
A kind names itself, gives a built-in default and checks a value. A value is always an
object. The kinds so far are `capacity_model` (7.1), `on_cost` (5.2) and `working_hours` (5.4), all below; 8.1 brings more.

`RuleSet` sets one rule for a subject: the plan's id for the whole plan, or a unit's id for
that unit and the units below it. Every rule is its own facet (`rule:<name>`), so two rules
on one subject both land. A plan editor sets one with `team_planning_set_rule`, which takes
any registered kind, so a story that adds a kind adds no tool; `team_planning_clear_change`
with facet `rule:<name>` hands it back to the parent, and `team_planning_rule` reads one
as a scenario resolves it. `Map#rule(name, unit_id:)` reads a
rule in this order:

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

### On-costs as built

An on-cost model prices what a seat costs on top of its base pay.
`TeamPlanning::OnCostModel` is the interface and `TeamPlanning::OnCostModels` the registry.
A model checks its params and returns a `Figure` in the base's currency: an exact
`Rational` and the `Step`s of its working. It never converts, since exchange rates apply
once, at report time (5.3).

- **Flat:** one percentage of base pay.
- **By country:** a percentage per country and one for every other country, or none
  recorded. The Org Graph holds country as the HRIS gives it, as free text, so a country
  matches ignoring case and spacing.
- **Itemised:** named parts, summed. A part is a percentage of base pay, or a fixed amount
  a year for a full-time seat in a stated currency, scaled by the share of a full-time year
  being priced. A fixed amount in another currency than the seat's is refused when priced.

The `on_cost` rule chooses the model and its params. Its default adds nothing, so a plan
costs base pay alone until a tenant or plan chooses. Read at a seat's unit, a unit can
price its subtree differently. Cost prices each seat with
`TeamPlanning::RuleKinds::OnCost.on_cost_of`. Rates are tenant configuration, as pay bands
are, not a person's data, so the rule is not shreddable.

The `working_hours` rule says how many hours a full-time seat works in a year, so an
hourly pay band can price a year. Its default is 40 hours a week for 52 weeks: 2,080.
A month band is twelve months; a year band is itself.

### Capacity as built

A capacity model prices a seat. `TeamPlanning::CapacityModel` is the interface and
`TeamPlanning::CapacityModels` the registry, built like the rule kinds. A model names
itself, checks its params and returns a `Figure` for one place: an exact `Rational` and the
`Step`s of its working, which a person's card can list. Two models are built in: `per_fte`,
one unit per FTE, and `units` (below).

The `capacity_model` rule chooses a model per role family, and a role can choose another.
Its default chooses nothing, so a plan counts nothing until a tenant or plan says how. Read
at a seat's unit, a unit can choose differently for its subtree.

`TeamPlanning::Capacity` reads the settled scenario map. A seat is a person, or the FTE a
position's occupants leave open, and each place it holds (a unit or a position, and its
share of the seat) is priced on its own:

- **A place in a position** does that position's work, so it takes the position's role
  and level, whether a person fills it or it stands open. A position counts only for the
  FTE its occupants leave, so a filled one is counted once, through its people, and an
  open one is priced exactly as a filled one would be.
- **A person placed straight in a unit** takes their own role and level: their title and
  level as the map holds them, through the tenant's title mapping, as the HRIS sync
  resolves them (`Integrations::HrisTitleResolution`). Never through
  `PersonFrameworkAssignment`, whose dates are not the scenario's. 3.14, which changes a
  person's role or level in a scenario, must put the change on the map's `Member`, so
  capacity follows it.
- **An FTE the map doesn't hold** counts as 1, and the working says so.
- **An allocation the HRIS didn't give** shares what the person's other places leave, and
  the working says so.
- **A leaver** counts nowhere, with the reason "leaving": their backfill position carries
  the seat, and their own place in it never counts as filling it.

A place no model covers counts nowhere and is listed as unclassified with its reason: no
title, a title mapped to no role, a role not in the framework, a position since closed, no
model chosen, or a model no longer registered. A place in a unit gone from the map counts
for the scenario but under no unit. For no model, or one no longer registered, the checks
credit the plan's capacity rule that decided it, the nearest unit's or else the plan's,
however late the person's own change landed.

**A planner's override** (7.3, `CapacitySet`) replaces one place's figure: a person's
capacity in a position, or straight in a unit, as a number in that place's model's units.
Each place is its own facet, `capacity:<position or unit id>`, so clearing one keeps the
others. The model still prices the place: its figure rides along as `calculated`, and the
working ends with an "=" step naming it, so a reader sees what the planner replaced. An
override applies only to a place a model prices, so it never turns an unclassified place
or a leaver into a count; such a place keeps its reason and is marked `overridden`, so the
override stays visible. The amount is the plan's judgement about a named person, so it
seals under their key like a planned level. Once they are forgotten the place counts
nowhere, with the reason "override_unknown", and never falls back to the model's figure.
The write refuses only a malformed override; one on a place the person doesn't hold in the
step is an Attention item.

A model gets the whole map with each seat, and `Facts`: each seat's level ordinal, its
roles and an open seat's FTE. Totals are kept per model, per unit and for the scenario, and never
summed across models. Figures stay exact; `team_planning_capacity` sends them as decimal
strings, with each model's symbol (`u`, `FTE`) and description, and only the display rounds.

**On screen** (7.4, [#296](https://github.com/espaliahq/espalia/issues/296)), the map shows
a strip of the scenario's totals per model, each beside Today's, as cost is. A unit's card
carries its own total, and each person's place and each open position carries a figure that
opens to its working; an open position's figure looks like a filled one so the two compare.
The strip equals the unit totals plus whatever counts in no unit on the map, which it names.
The scenario table shows the same total per scenario. Once a capacity model is chosen for any
role or family, at any unit or plan-wide, Attention lists each place no model covers, as `capacity:<unit or position id>`, except a leaver's, a
forgotten person's override and a closed position's, which are explained elsewhere.

#### The units model

`TeamPlanning::CapacityModels::Units` ([#265](https://github.com/espaliahq/espalia/issues/265))
counts a seat in units, where one is roughly what a solid mid-level contributor delivers.
Every number below is a parameter of the `capacity_model` rule; the defaults are
illustrative, never an organisation's figures.

```json
{"base":{"start":"0.4","slope":"0.3","knee":4,"decay":"0.5"},
 "fixed_cost":{"default":"0.1","by_level":{}},
 "per_report":{"direct":"0.1","skip":"0.03","deeper":"0.01"},
 "report_weight":{"default":"1","by_level":{"1":"1.5","2":"1.25"}},
 "manager_role_ids":[]}
```

Levels are framework level ordinals. The base rises by `slope` a level to the `knee`, and
each level beyond adds `decay` times the step before, so it never passes
base(knee) + slope × decay ÷ (1 − decay). The defaults give L1 0.4, L3 1.0, L4 1.3, L5 1.45
and a cap of 1.6. `check` refuses a negative, a decay of 1 or more, a level that isn't
whole and an unknown key, naming the key and never its value.

A manager pays a fixed cost by their level and a cost per report by distance (direct, skip,
deeper), times the report's level weight, or the default weight when the report's level
resolves to none. The figure is max(base − cost, 0) × allocation × FTE: the whole cost is
taken before the seat splits across places. A cost past the base floors at zero and marks
the figure overloaded, with the excess. Each step names what it charges for.

`Units::Graph` reads who a seat manages from reporting lines, never from unit owners:
ownership says who may edit a unit, not who manages it. One principle runs through the
rules: a vacant seat and a filled one must stay comparable, so leaving a seat empty never
flatters a scenario.

- **A manager seat** is one with line reports, or a backfill of a leaver who had them, or a
  role in `manager_role_ids`.
- **A line to a position** goes to the one person in it, and to the open seat only while
  nobody is. A position two people share sends it to neither, and the report reads as
  unmanaged. So does a closed position, though someone still fills it. Otherwise a part-filled position would take every report and leave the person
  in it managing nobody, and a shared one would need a split the map can't give.
- **An open position**, a manager's included, counts against the nearest unit, walking up
  from its own, holding exactly one other manager seat: a filled one as a future direct
  report at its open FTE, or a vacant one as part of its span. Two in the nearest unit that
  has any, or none up the tree, and it counts against nobody, with a note saying which.
- **A vacant manager position counts against the manager above it**, which pays its open
  seat as a direct report and its team at skip level and below, as if the seat were filled.
  Otherwise a director with an open manager seat would pay nothing for that team.
- **A vacant manager position also takes, as direct reports, the people the same walk
  leads to who have no manager on the map.** Anyone a staffed manager holds stays theirs.
- **A vacant manager seat never takes its own manager as a report.** The head of the tree
  has no manager, so without this an open seat beneath them would take them, and with them
  everyone.
- **A leaver is never a report.** Their reports pass to their backfill, or to nobody,
  whether the line names the leaver or a position only the leaver fills.
- **A leaver keeps the positions they fill filled for the step**, so their capacity goes to
  their backfill or nowhere. Reopening those positions too would count the seat twice
  whenever a backfill exists.

### Cost as built

`TeamPlanning::Cost` prices a scenario over its period and prices the baseline over the
same days, so the two compare ([#288](https://github.com/espaliahq/espalia/issues/288)).
The baseline has no period of its own, so it is never the scenario costed.
`team_planning_cost` sends the totals, each unit and each cost centre, and the working of
every seat only for a unit the caller names.
`team_planning_scenario_costs` sends only the totals, for every scenario at once, reading
the Org Graph once for the plan: the Scenarios table's Cost column reads it
([#316](https://github.com/espaliahq/espalia/issues/316)). A single cost read also reads
it once, for the scenario and the baseline together.

- **A seat** is a person, or the FTE a position's occupants leave open, as capacity counts it.
- **Its level** is the person's own, a planned one winning. When theirs resolves to none,
  the position's level prices it, and the working says so (`level_source`). An open seat
  takes its position's level.
- **Its band** is the one for that level and the person's country, else the band for any
  location. An open seat has no country, so it takes the band for any location.
- **Its figure** is the band's midpoint for a full-time year (`working_hours` for an hourly
  band), times FTE, times its place's share of the seat, times the days held out of 365.
  The `on_cost` rule at its unit adds on-cost. A person's places always share their whole
  seat, so units and cost centres sum to the plan's total.
- **A leaver and their backfill** split one seat at the leaving date and never overlap:
  the leaver costs up to it, the backfill from the next day. A leaver with no date costs
  nothing in the period, and their backfill holds the whole of it. A backfill for several
  leavers opens each one's FTE on its own date, the earliest leaver first, and holds all
  period any FTE no leaver opens.
- **A cost centre** is the person's, from the Org Graph, or none. An open seat takes its
  position's cost centre, resolved as [Position to cost centre](#which-budget-line-a-position-draws-on)
  describes, and the working says how (`cost_centre_source`). No cost centre is a bucket of
  its own, counted like any other.
- **A seat that can't be priced** is listed with its reason (no level, no band, an on-cost rule
  that refuses it, or a level or FTE lost with a forgotten person's key), never counted
  as zero.

Every figure stays in its band's currency, exact, and the totals hold one sum per currency.
Each converts once, at the read, at the rate in force on the period's first day. A missing
rate leaves the converted total empty and names the pair and the date. Only the display
rounds. Plans reprice live: a changed band changes every plan's cost, and the report says
when a band was last added, changed or removed (`bands_changed_at`). The tenant keeps that
time, since a removed band leaves no row. A change to the working-hours or on-cost rules, or
to a rate, reprices plans too but does not move the stamp.

#### Cost on screen

A scenario's map opens with a Cost strip: its total, the difference from Today over the
same days, the period and what it is priced at, what sits in no unit on the map, and a
list of the seats left out. Each unit card shows its own places' cost beside its name.
The units and the no-unit figure add up to the strip's total, and the Scenarios table's
Cost column shows that same total. Today's row reads "No period of its own", and Today's
map shows no cost. The strip and column appear only once a band prices something, and a
scenario that can't be priced keeps its map and reads "Can't be priced" in the table.
Figures round to three significant figures (`Views::Plans::CostMarks::Format`); no band
minimum or maximum shows on either page.

### The see-pay right as built

A member holds the see-pay right or not
([#300](https://github.com/espaliahq/espalia/issues/300)). Two plan events carry it,
`SeePayGranted` and `SeePayWithdrawn`, each naming who made the change. `PlanPolicy#see_pay?`
answers for the caller, and every read of band ranges or actual pay asks it. Today that is
`team_planning_cost`, which gives a holder each band's minimum and maximum beside its
midpoint and everyone else the midpoint, and says which in `pay_view` (`band_ranges` or
`band_midpoints`). Totals are the same in both, since midpoints price every seat until
actual pay arrives in 5.6. An agent over MCP gets the view of the person it acts for.

- **Who changes it.** Only a holder grants or withdraws, and only for a member. The creator
  holds it from the start, and plans from before the right have their creator only.
  Removing a member withdraws it; adding them back does not restore it. Only a member still
  active and remembered can be given it.
- **No lock-out.** The last holder cannot withdraw from themselves or be removed. The stream
  counts holders and the command handler counts the reachable ones, so a holder who left or
  was forgotten doesn't count as the one who remains.
- **Recovery.** A plan whose holders have all left or been forgotten is locked out of pay.
  A tenant admin can restore it, unread, with `team_planning_restore_see_pay`. Each reachable
  editor gets the right, recorded as the admin's grant with `recovery: true`, and the tool
  returns only `{ plan_id, restored: true }`. The admin never opens the plan, so being a tenant
  admin still opens no one else's plan. A plan that isn't locked out, or that the admin
  can't see, refuses with the same "No such plan". A frozen plan is refused too, since its
  editors are gone and a tenant admin can already delete it.
- **Shown.** `team_planning_plan_members` and the plan's members panel show who holds the
  right, who gave it and when, and whether a tenant admin restored it. A holder can then
  withdraw a restored right from the others. On a locked-out plan the panel tells members
  to ask a tenant admin.
- **Forgetting.** A forgotten holder keeps the right as a former member, as they keep their
  membership, and no longer counts as a holder who can act.

The `team_planning/plan_members` projection carries the right, so its version moved to 2
and it needs a rebuild on deploy.

### Clearing and pinning

`ChangeCleared` hands one facet of one subject back to the scenario's parent. The aggregate
keeps every change, pin and clear a scenario makes in one ordered log, and works out what is
in effect from it, so a clear hides the earlier changes for its key and resolution reads the
parent's value again. Nothing leaves the log, so undoing a clear (3.10) can bring them back.
Once `AssignmentSet` lands (3.6), clearing a person's assignment clears their whole
placement list, since the list is one facet.

`ChangePinned` keeps what a scenario inherits for a facet as it resolves now, so a later
change in the parent no longer reaches it. It records the end state, the kind of change it
stands for, and where the value came from: the ancestor scenario and the event that set
it, or neither when the parent's resolved map gave it (a rule above the subject, or the
baseline). The aggregate replays a pin as a change of that kind. The baseline has no
parent, so it pins nothing, and a scenario can't pin a facet it already changes.

To pin a value the baseline gives, a kind reads its end state off a map with
`Change.read_from(map, subject_id:, facet:)`. The caller chooses the map: the parent's
resolved map for a pin, and a map built from the Org Graph today for a change's status
(4.3). A kind that doesn't implement it can still be pinned from an ancestor's change.

`TeamPlanning::ChangeKinds.all` finds every kind of change: each `Change` subclass in
`app/contexts/team_planning/events`, so a new kind touches only its own file. It loads that
directory before it looks, since the projections subscribe before production eager-loads. A
test checks every kind is complete. A clear or a pin acts on a subject and facet, whichever
kind last set it; pinning a baseline value asks each readable kind of the facet in turn. The overrides
projection subscribes through it and writes
`team_planning_overrides`: one row per scenario, subject and facet the scenario sets or
pinned. `team_planning_overrides` lists them, each beside what the scenario would inherit
without it, and says when a pin's parent has moved on. Reconcile (4.5) reuses both: keep
the plan is a pin, and follow reality is a clear.

### Undo

Undo and redo are events that point at the event they reverse: `ChangeUndone` and
`ChangeRedone` name it, with its scenario, subject and facet, and the change or pin then
in effect there (`in_effect_event_id`), so the overrides projection writes it without
replaying the stream. The stream is never edited.
An undone change stays in the log and drops out of what the scenario resolves to, so the
change before it, or the parent's value, shows through. Undoing a clear brings back what
it cleared, and undoing a pin hands the facet back to the parent.

Undo works on one subject and facet at a time, newest first. A change a later one
replaced can't be undone until the later one is, and the refusal names it. Redo is
refused the same way once a newer change lands on that facet. Undo with no change named
takes back the caller's own latest change that can still be undone; Redo restores what
their latest undo took back. Each person redoes only their own undos, and a change they
make ends what they can redo, as in an editor. Undo and redo are for editors, like any
other change.

A scenario's history is `team_planning_history_entries`, one row per change, pin, clear,
undo, redo and note, in order, with who made it and, while it stands undone, who undid it.
The baseline's history also lists each update to today, with the base it left and the
conflicts it carried.
`team_planning_history` lists it, a hundred entries a page, and a forgotten person reads as
a former member.
Production already holds changes, pins and clears, so the deploy that ships the history
needs `REBUILD_ON_DEPLOY=team_planning/history` to fill it. Without it, predeploy's
`verify` stops the deploy. The
history and overrides projections read events through one mapping,
`TeamPlanning::ChangeEntry`, so they agree on what each event did. A shreddable value
never reaches either table: the history names the field in `sealed_fields` and leaves
the value out. The note is the one exception, held in a sealed column (see below).
Removing a scenario drops its history.

### Notes

**As built in 3.13b** ([#273](https://github.com/espaliahq/espalia/issues/273)): every
change and pin may carry a `note`, the planner's reason, such as why someone moves.
**The note follows the key of the change's subject.**

- **A note on a change to a person seals under that person's key in the plan.** A kind
  whose subject is a person declares `about_a_person`: `AssignmentSet`, `CapacitySet`,
  `DepartureSet`, `DepartureWithdrawn`, `LevelSet`, `PlanDataSet` and `ReportingLineSet`. Forgetting the
  person removes the note with the level, the pay and the rest. An assignment of a
  placeholder hire seals under the placeholder's id, a key only deleting the plan
  destroys.
- **Any other note seals under the plan's key**: on a unit, a position, a rule, a
  placeholder hire or a succession. The `Change` base declares `shreddable :note, by:
  :plan`, so a new kind gets that with nothing declared. Forgetting a person leaves such a
  note readable, the accepted limit of free text
  ([#110](https://github.com/espaliahq/espalia/issues/110)), so the tools ask planners to
  keep personal details out of it.
- **Every copy chooses the same key.** `ChangePinned`, `ChangeNoted` and both read models
  seal through `TeamPlanning::ChangeKinds::NOTED_PERSON`, which reads the subject and
  facet: the subject's key when the facet's kinds are about a person, else the plan's.
  Kinds that share a facet share a subject, and a test holds them to it.
- **Deleting the plan removes every note**, since it destroys every key the plan holds.
  Destroying the plan's own key alone would leave notes on people readable under theirs.
- **Once removed, a note reads as `{ removed: true }`**, as a value does. The history still
  shows that a note was written, by whom and when.
- **A note is never part of the end state.** `note` is in `Change::FIELDS`, which every end
  state leaves out, so resolution, `same_end_state?`, status and drift read two changes
  that differ only in their notes as the same. An end state can't set `note`.
- **Every write tool takes `note`,** at most 2,000 characters, through
  `Operations::TeamPlanning::ChangeWrite`. A blank note is none, and a change without one
  stores no note field, as it did before notes.
- **`ChangeNoted` rewrites or clears a note** on a change or pin that still stands in its
  scenario: not undone, not cleared and not replaced. It carries the noted event's id, its
  subject and facet, the note (nil clears it) and who wrote it. It is not an entry of the
  log, so it can't be undone and doesn't end what anyone can redo. `team_planning_note_change`
  exposes it; it is for editors, like any other change, so a frozen plan refuses it.
- **The note follows its change.** The overrides row holds the note of the change in
  effect. An undo or redo that brings a change back brings the last note written on it
  before then, read from the plan stream.
- **Both read models seal the note.** `team_planning_overrides.note` and
  `team_planning_history_entries.note` are shreddable columns under the same key as their
  event, copying the sealed form from it, so forgetting the person or deleting the plan
  makes every copy unreadable at once. A history row for a change or pin keeps the note
  it was made with; each `note` row keeps one rewrite and names the change in
  `noted_event_id`. `team_planning_overrides` and `team_planning_history` show it as
  `{ value: }`.
- **No rebuild.** No stored event held a note before 3.13b and the new columns start empty,
  so neither projection's `CODE_VERSION` moved.

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

### Updating to today

`team_planning_rebase_plan` moves a plan's base to today, a UTC day, and nothing else.
Every scenario keeps its changes and resolves them over the Org Graph as of the new base,
so someone who joined since the old base comes onto the map, and someone who left drops
off it, with "has left" against any change that still places them. The first step after
the baseline starts on the new base.

A base only moves forward. The update is refused when the plan already stands on today,
or on a day still to come, which already reads the Org Graph as known now. It is refused
when the first step would end before today, naming the step, and when the plan has moved
since the caller looked: `team_planning_rebase_preview` returns the base it read, and the
update must pass it back. Undo never reverses an update.

The preview shows the drift being taken in, in the drift report's own shape, and counts,
for the baseline and each scenario, the changes that read done, pending and conflicting.
It lists the conflicts too. It reads all of this over one base, and is refused if the
plan moves while it reads.

On the web, an editor finds "Update to today" on the Changes tab while the base is in
the past ([#337](https://github.com/espaliahq/espalia/issues/337)). It opens the preview
under the plan, at `/planning/:id/update-to-today`, and its confirm posts back the base
the preview read. A viewer sees no button and is refused the update, and a frozen plan
has no editor left to offer it to.

Once the base is today, a change that disagreed with the Org Graph would read pending:
today and the base say the same thing. So `PlanRebased` records each conflict found at
that moment, as the scenario it read conflicting in, its subject, its facet and the
change that scenario resolved to, never a value. A change's status depends on the
scenario read, since a step can reshape what an inherited change lands on, so each
scenario keeps its own. The update finds them afresh rather than trusting the preview,
and a change made after that read never inherits a conflict it didn't have. The
conflict stays open while the scenario still resolves to the same change. A set, pin,
clear or undo along its chain ends it, a redo of the same change brings it back, and a
later update replaces the set, keeping the date a conflict was first found. Nothing stores the result: it is derived from the stream on
each load.

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

### The drift reader

`TeamPlanning::Drift` reads `OrgGraph::ChangesBetween` by learned date, from the day
before the base date to today, so it covers exactly what the baseline leaves out. A
backdated correction learned since the base shows with the day it took effect. A plan
whose base is still to come has no drift.

Each change says what it meets in the plan: for each scenario, the latest planned change
to the facet it moves. Each kind decides which Org Graph changes move its facet, through
`Change.subject_moved_by`, which returns the subject's id or nil. A person's placements
are one facet, so a move in one placement meets the plan's whole list for that person.
A retirement meets what moves a unit set, as both hold the facet `unit`. No Org Graph
change names a planned succession, whose id is the plan's own, so a succession meets none.
A change applied from this plan comes back `from_plan`, matched through the `plan_id` on
its event; nothing sets one until approval exists. Whether a planned change is done,
pending or conflicting is 4.3's status, below.

`team_planning_drift` gives the same report to MCP, with people by id and a `names` map
beside them.

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

### The status reader

`TeamPlanning::Status` takes a plan and a scenario and gives one status for each subject
and facet the scenario resolves, down its resolution chain, so a change an alternative
overrides takes the alternative's end state. It reads two maps in the baseline's shape:
today's, from `Baseline#map_on(today)` as known now, and the baseline itself. Each kind
reads its end state off both with `read_from`.

- **Done**: today reads the planned end state. A change that plans no change from the
  base is done.
- **Pending**: today still reads what the base held, or what the step before the change's
  own step plans: once Q1's move lands, Q2's next move for the same person waits its turn.
  So is a subject only the plan holds, such as a new unit: neither map has it.
- **Conflicting**: today reads none of these, as when someone the plan moves has left.

A plan whose base is still to come holds every change against today, so nothing reads
conflicting before the plan starts.

A conflict an update carried forward (see *Updating to today*) reads conflicting, with
`since` set to the day of the update that first found it, while the scenario still
resolves to the same change. A change that reads done reads done, and if the Org Graph
then moves off its end state, the carried conflict shows again: the plan stores no
record that it was ever done.

A person's placements are one facet, so a planned list is done only when the whole list
matches, and a list matched in part conflicts. Only a kind that is `readable?` and that the
Org Graph can move (it implements `subject_moved_by`) or find (it overrides
`read_org_graph`) has a status: a unit set, a retirement, a succession, an assignment, a
reporting line and a departure. A rule and a position are plan-only, so each would read
pending forever.

Today's map is `Baseline#map_on(today, history: true)`, which adds the units the Org Graph
has retired, the successions it holds and the people who have left, from `OrgGraph::AsOf`'s
`retired_units`, `successions` and `left_ids`. The plain map and the baseline leave all three
out, as a plan keeps its own. A departure reads done once the Org Graph has the person
leave, and pending while they stay. The Org Graph knows only that they left, not the step
or the backfill, so a leaver reads as the plan has them leave. A
retirement reads done once the Org Graph has retired the unit, whatever it last looked
like, and pending while the unit is live. The Org Graph mints its own succession ids, so
a kind reads its end state off today's map through `Change.read_org_graph`, which a
succession overrides to find the Org Graph's successions by their predecessors. It joins
every one that shares a planned predecessor, as the Org Graph may record a merge in parts.
The joined sides read done when they match the plan, conflicting when they don't, and
pending when there are none. A succession the Org Graph held on the base date came before
the plan, so today's map leaves it out.

A reporting line to a position reads done once the Org Graph names, as the person's
manager, someone the scenario seats in that position.

The Org Graph can't say which position someone fills, only where they are. So a placement
in a position is held against the place it settles to on the scenario's map: the
position's unit, at the placement's allocation, with its role only when the plan names
one. It reads done once the person is in that unit at that allocation. Names come
last and from today, so a forgotten person reads "Former member", a renamed unit its new
name, and a subject only the plan holds has none. `Raised` will join these once
`ChangeRaised` exists. `team_planning_status` gives the same read over MCP.

### The changes tab as built

The Changes tab ([#287](https://github.com/espaliahq/espalia/issues/287)) draws three reads
and decides none of their rules: the drift, the status of one scenario's changes, and what
in that scenario needs attention. A picker chooses the scenario, as pills on a wide screen
and a list on a phone. Each drift change links the scenarios whose plan it meets.

Drift and status each give a change's `sources`, from `TeamPlanning::SourceOfTruth`: who
supplies what the change moves, so the place someone goes to make it happen. A person fact
comes from its `OrgFactProvider`, or from Espalia where nobody chose one. A level, a manager
and a departure move a person fact. A membership the Org Graph holds comes from whoever
supplied it, as Espalia can hold one in a unit an HRIS mirrors. A unit, a succession and a
planned placement come from the providers of the units they touch, as a unit mirrored from
an HRIS takes its members from the sync. A unit only the plan holds is Espalia's. Drift's `names` cover units as well as
people, so a move reads "from Payments to Growth".

Attention gives each item its `sources` too. Someone the plan can't place, as they joined
after the base or have left, is fixed where employment status comes from. A manager item is
fixed where the manager fact comes from. Every other item is fixed in the units it touches:
its own, its position's, a succession's, the places of someone over or under allocated, the
place a capacity item names, or the retired unit that broke it. A capacity item for someone in
no unit falls back to Espalia.

Each planned change shows its note beside it ([#292](https://github.com/espaliahq/espalia/issues/292)),
rendered as prose. `team_planning_status` gives an entry its `note`, read off the override
the change projects, so it holds the latest one written. A removed note reads "Note removed"
rather than vanishing, so the change doesn't look as if nobody explained it. An editor writes,
rewrites or clears a note in place, through `team_planning_note_change`, on the scenario that
made the change. For an inherited change that is not the scenario shown. Rules and positions
have no status, so their notes don't appear here.

## Plan-held data

Values a plan holds on top of the Org Graph (a pasted salary, a corrected level, a hire not
in the HRIS yet) are `PlanDataSet` events. A value about a named person, such as their
pay or a corrected level, is shreddable under that person's key in the plan. Every other
value, every note on a change whose subject is not a person and every scenario
description are shreddable under the plan's key. A note follows its subject's key, so a
note on a change to a person seals under that person's key in the plan.
Deleting the plan deletes every key it holds. The events remain and still say that
something was set; what it was is unreadable at once, and gone for good once the backups
taken before the deletion have expired.

Two consequences of [the aggregate guard](shreddable-fields-design.md):

- The aggregate cannot decide anything on a plan-held value. Checks that need the value,
  such as a salary outside its band, are projections. That matches the rule that
  guardrails are shown and not enforced.
- "Unchanged, so do nothing" cannot be checked in the aggregate for these fields. The
  Operation checks it against a projection.

**As built in 3.14** ([#270](https://github.com/espaliahq/espalia/issues/270)):

- **A placeholder hire is its own kind, `PlaceholderSet`.** A key is chosen per event
  class, and a placeholder is not a person, so its label, level and FTE seal under the
  plan's key. `PlanDataSet` holds a person's corrected level or FTE, one facet per field,
  and `LevelSet` a planned promotion, both under the person's key. Forgetting someone
  shreds their two and leaves every placeholder as it was.
- **Reads unseal from the stored events.** The aggregate keeps redacted copies, so
  Resolution and Status re-read the winning sealed changes by event id
  (`TeamPlanning::Repository#sealed`). No sealed read model was needed.
- **Precedence:** a planned promotion, then a corrected level, then the Org Graph's.
- **A shredded value reads as unknown.** `Member#planned_or_own` gives `:unknown`, the map
  shows `{ removed: true }`, capacity counts the FTE as not known (at 1) and gives no
  target for the level, and a change's status reads `unknown`. Nothing raises, and
  nothing falls back to the Org Graph's value.
- **A sealed value can't be pinned yet.** `ChangePinned` copies an end state, and a sealed
  one can't be copied in clear, so pinning one is refused with a reason.

## The headcount budget

The organisation's approved budget is tenant configuration, like pay bands: a `budget_lines`
table that only tenant admins hold, on the Budget page or through the `tenants_*_budget_line`
tools. Every plan reads it live as its root's default. A plan member sees a line only
through their plan's read, and the tenant tools refuse everyone else with no detail. What a
plan changes stays in the plan: a budget line approved for a person already employed is close
to that person's pay, so a plan's own lines and changes belong with its other sensitive
values, under the plan's key and deleted with it
([#302](https://github.com/espaliahq/espalia/issues/302)).

- **Headcount budget only.** A budget line is permission to spend on people: a period, an
  amount or a head count or both, and optionally the role, level, location and cost
  centre it was approved for. Cost centre is the label the Org Graph carries for a
  person, used for grouping. Accounts, ledger codes and every other financial or
  accounting identifier are out of scope.
- **A plan changes the budget with plan data.** `BudgetLineSet` and `BudgetLineCut` add,
  change or cut a line in a scenario, and a descendant changes them like anything else. The
  amount is shreddable under the plan's key. A tenant line keeps its id in every scenario; a
  line the plan adds gets one the plan mints. The baseline holds the approved budget as it
  is, so only a scenario changes it. Removing a tenant line a plan has changed or cut
  leaves the plan's change orphaned: `team_planning_budget_lines` lists it under `orphaned`,
  and Attention flags it rather than dropping it. Until the budget tab (6.7), a plan's lines
  are reached over MCP.
- **Money keeps its currency.** An amount keeps its own currency and period, a year or a
  month, as a pay band's does, and is never converted. A line with a head count and no amount
  has no amount, never zero.
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

As built in 6.2 ([#325](https://github.com/espaliahq/espalia/issues/325)): the rules are the
`cost_centre` rule kind, set through the generic rule write. A matcher names a unit, a role
or a role family, or a unit with one of the other two. Each position's result records its
source (`position`, `person`, `rule` with the rule's index, or `none`). Step 2 reads only the
occupant's own cost centre, the one with the largest allocation first: no event carries a
plan's change to a person's cost centre yet, and the mismatch check in 6.6 is where one is
needed.

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
| Timeline | One path through the scenario tree, with lanes and moves. Read on demand by `TeamPlanning::Timeline`, not stored. |
| Headcount walk | Per step and unit: opening, hires, known and expected departures, transfers, closing. Drawn as a lane of the timeline. |
| Checks | Every warning, with guardrail checks marked. |
| Change list | The approved changes with their derived status. |

Projections must rebuild with every key forgotten. That rebuild is how a deleted plan's
values leave the read models.

## Permissions

- A plan is private to its members, each an editor or a viewer.
- Seeing pay is a separate permission. Without it a member sees band midpoints. See
  [The see-pay right as built](#the-see-pay-right-as-built).
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

**Erasure inside a live plan.** When the Org Graph forgets a person, the transaction
that writes `PersonForgotten` destroys that person's key in every plan at once. Every
value a plan held about them, such as their pay, a corrected level or a planned
promotion, becomes unreadable. They stay in each plan's history as a former member with no identity.

Notes on changes to them go too, since a note follows the key of its change's subject.
One thing can still name them: a note on another change, such as a unit's or a rule's.
That note is free text under the plan's key, so one that mentions the person stays
readable to the plan's members until the plan is deleted
([#110](https://github.com/espaliahq/espalia/issues/110)). The note tools tell planners
to keep personal details out of it. Deleting the plan is the remedy when that is not acceptable.
