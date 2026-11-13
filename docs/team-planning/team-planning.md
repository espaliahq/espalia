# Team Planning — module description

> Status: proposal. Nothing here is built. This page says what the module is for and what
> it can do, so the design that follows has something to answer to. It names no
> organisation, person or figure. [The index](README.md) lists the mockups and the plan.
>
> How the data is held is in three companion designs:
> [Team Planning](team-planning-design.md),
> [the Org Graph](org-graph-design.md) it depends on, and
> [shreddable event fields](shreddable-fields-design.md).

Team Planning lets an organisation explore how its teams could be shaped: who works on
what, at what cost, with how much delivery capacity and which capabilities, across
scenarios laid out along the calendar. It starts from the roster Espalia already keeps
current and from what Espalia already knows about each person's capabilities.

It grew out of a year of planning real teams with a standalone tool that read a
spreadsheet export. The capabilities below are the ones that earned their place there.
The two that tool could not have are the reason to build this inside Espalia: a roster
that is never stale, and capabilities as a planning factor.

## The principle: the Org Graph is what is known, a plan is what might be

Two sources of truth, never mixed.

- **The Org Graph** is Espalia's best-known view of what currently is. It claims no
  authority of its own: most of it mirrors other systems. Each kind of fact has one
  provider: the HRIS for people, an applicant tracking system for open positions. Where no integration holds a fact, such as squads
  beneath a team or a person's split across two teams, Espalia holds it.
- **A plan** is the truth about what is in that plan, and nothing else. It is always an
  overlay: planned changes layered over the Org Graph, each one marked as planned.

A plan relates to the Org Graph as a branch relates to the main line. The Org Graph is the main
line and moves by itself as the organisation does. A plan is a branch of changes on top
of it. The same logic then answers most questions about how the module behaves:

- A plan never edits the Org Graph. It only states differences from it.
- When the Org Graph moves, the plan is updated to it. Nothing a planner layered on
  purpose is lost.
- A planned change the Org Graph now matches is done. It stops being a difference.
- A planned change the Org Graph does not yet match is carried forward.
- A planned change the Org Graph contradicts is a conflict. Someone reconciles it; it is
  never silently kept or dropped.
- Scenarios are branches of branches, and the same rules hold between a scenario and its
  parent.

Everything below is this principle applied.

## The second principle: every figure is actual, planned or forecast

A plan about next year mixes three kinds of statement. The module keeps them apart.

| Source | What it is | Example |
|---|---|---|
| Actual | A fact in the Org Graph. | Someone has resigned. |
| Planned | A decision set in a scenario. | That position will be closed. |
| Forecast | What an assumption produces. | About two more people will leave this year. |

- **Only planned changes are approved.** Nobody approves a forecast, and a forecast is
  never in the list of changes to carry out.
- **Each moves for a different reason.** Actual moves when the organisation does.
  Forecast moves when an assumption or what feeds it changes. Planned moves only when a
  person edits it.
- **A forecast names nobody.** It is a number for a unit and a step: so many departures,
  so many promotions, so much more pay. Naming a person is a decision, and a decision is
  planned.
- **One becomes the next, and is never counted twice.** A planner who decides a forecast
  will happen sets it as a planned change, and it leaves the forecast. A planned change
  that comes true is actual, and it leaves the plan.
- **Every total says what it is made of.** Under each total, how much is actual, planned
  and forecast. A budget built on decisions reads differently from one built on an
  estimate.
- **A closed step scores its forecast.** What was forecast is shown beside what
  happened, so an organisation learns how good its assumptions are.

## What a planner can do

### Start from today, without an import

The baseline is the Org Graph as it stands: people, levels, roles, managers and departments
from the HRIS sync, with team structure from the HRIS where it holds it and from Espalia
where it does not. The baseline is itself a scenario. Nobody exports a file to begin.

A plan sits on the Org Graph as of a date, so its numbers do not move while people discuss
it. When the Org Graph moves underneath, the plan says so: a person the plan still places has
left, a hire the plan held as a placeholder has arrived, a reporting line the plan assumed
has changed. Catching up with today is an explicit update to today that lists what changed. See
*Keep up with reality*.

### Play freely: the plan owns its data and its rules

A plan is a sandbox. Everything it reads has a default from somewhere else, and
everything can be changed for the sake of the plan without touching the source.

- **Data.** The roster comes from the integration, but a plan can hold its own values on
  top: a person's salary cost from a spreadsheet, a corrected level or location, an
  FTE the HRIS does not carry, a hire who is not in the HRIS yet. These
  live in the plan and nowhere else. They never reach the person's record, their
  development history or any other plan.
- **Configuration.** Pay bands, on-costs, exchange rates, the capacity curve, which roles
  deliver capacity, the unit taxonomy and the budget rule all start from tenant defaults.
  A plan can change any of them.
- **Inheritance.** Values resolve in one order: integration, tenant default, plan, then
  each scenario down the chain. Data, configuration and rules are set the same way as a
  move or a position: stated in a scenario, inherited by its descendants, and changed again
  wherever a descendant differs. So one scenario can ask "what if on-costs rise", and
  another "what if this budget were an envelope".
- **Overrides are always visible.** Anything set in place of what it would otherwise be
  carries a mark wherever it appears: on the map, in a table, in a total it feeds. The
  mark opens to show the value it replaced, where that came from, who set the override
  and why, and offers to clear it. This is one affordance for the whole module: a salary
  entered into the plan, a changed on-cost rate, a capacity figure typed over the
  calculated one and a person placed differently from the parent scenario all look and
  behave the same way. A plan can list everything it overrides. When the source later
  changes under an override, the plan says so and keeps its own value until someone
  decides.
- **Guardrails are shown, not enforced.** A tenant can state the rules it expects plans to
  meet: the budget, how strictly positions must follow it, limits on span or level mix. A plan
  that breaks one says where and by how much, and carries on. Tenant validation only
  becomes binding if a plan is ever submitted for approval, which is a later workflow.
  Until then nothing stops a planner trying the thing the organisation would not sign.

### Describe structure, demand and people separately

- **Units** are structure. A tenant names its own levels (stream, squad, team, tribe) and
  nests them.
- **Positions** are demand. A position is a role at a level in a unit, with an FTE. A position is
  filled or open, and an open position records why it exists: a **backfill** for someone who
  left, or new headcount.
- **Budget** is permission to spend. It is its own thing, not a property of a position. See
  *Stay within the approved budget*.
- **Assignments** join a person to a position with an allocation. One person can hold parts of
  several positions.
- **Reporting lines** are a graph over people. They are never inferred from the unit
  tree, and a scenario can override them.

A position's role and level are the framework's roles and levels. That one link gives a position
its price band, its capacity and its capability expectations.

### Layer scenarios as changes

A scenario forks from a parent and holds only what it sets itself: where a person is
placed, a position opened or closed, a unit renamed or removed, someone marked as leaving with
a position linked to them, who reports to whom, a rule or a figure. Everything else it
inherits. Each change can carry a note saying why. Chains run as long as the plan needs:
this quarter, next quarter, next year's base case, a funded variant.

A change says where something ends up, not how it got there: "this person is in that
team at half time", not "move them from here". That is what lets the layers stay
consistent as they are edited:

- **Changes flow down, never up.** A change made in a scenario shows in that scenario and
  in every descendant. Its ancestors are untouched.
- **A descendant's own changes survive.** Where a descendant has explicitly set the same
  thing, it keeps what it set. The ancestor's change becomes the new base underneath, and
  the descendant's change is applied on top of it. Editing an early layer never erases a
  decision made in a later one.
- **A change that no longer fits is flagged, not dropped.** If an ancestor removes the
  team a descendant placed someone in, the descendant keeps the change and shows it as
  needing attention.
- **Explicit is a state anyone can set or clear.** Every item shows whether the scenario
  inherits it or sets it. One action makes an inherited item explicit as it stands, which
  pins it against later changes above. One action clears an explicit change, and the item
  follows its parent again. It is the same mark and the same clear as any other override.

Every figure is measured against the baseline, not the parent, so a reader always sees the
distance from today. A renamed unit is compared with what it used to be.

### Work directly on the map

The team map is where a plan is edited, not only where it is read.

- **Drag and drop.** Drag a person between units and positions, a position between units, a
  person onto an open position to fill it. The drop changes the scenario on screen, under the
  rules above. An allocation, a role or a reporting line can be set as the person lands.
- **An Unassigned bucket.** Everyone on the roster the scenario places nowhere, or only in
  part, appears in a bucket the map keeps by itself. Drag from it to place someone; drag
  to it to take them out of a team. It is derived, never a unit to maintain, and it is
  where new arrivals from the roster show up.
- **Undo.** Every change to a plan can be undone and redone, whether it was a drop, a
  typed figure, a cleared override or a changed rule. A scenario keeps its history of
  changes, with who made each one.
- **See the effect at once.** Cost, budget, capacity and checks update with each change,
  for the scenario and for the descendants it flowed into.

### Cost a scenario

Positions are priced from pay bands per role, level and location, with on-costs, in the
band's own currency. Conversion to a reference currency happens once, at report time.
A position costs for the part of the period it exists, so a hire planned for the third
quarter costs half a year. Costs roll up by unit and by cost centre, and every scenario
shows its difference from the baseline.

Pricing from bands needs no pay data, and is the default. A filled position can be priced
from the person's actual cost instead, from a pay integration or from figures entered
into the plan. Either way it needs its own permission. See *Sensitive by default*.

### Forecast what has not been decided

A plan that covers a year is wrong if it assumes nobody leaves, nobody is promoted, pay
stands still and every hire starts on the first day. A plan holds an assumption for
each, and each produces a forecast. Assumptions are rules like any other: they start
from the tenant default, and a plan or a scenario can change them, for the whole
organisation or for one unit.

- **Attrition.** A yearly rate. The forecast reduces each later step by the expected
  number of heads, keeps their budget for the backfills, and leaves their positions open
  for the time a hire takes. A departure the plan knows about is planned, and is not
  counted again.
- **Promotions.** Promotion readiness in Espalia says how many people at each level in a
  unit are likely to move up, and the tenant states when promotions take effect. The
  forecast adds their cost and the change in what they deliver. A planner who decides a
  promotion will happen sets it as a level change on that person, and it leaves the
  forecast.
- **Pay increases.** The simple assumption is one yearly percentage. The better one uses
  what Espalia already knows: a person's ratings against their level say where they
  should sit in the pay band for that level, and the forecast moves pay toward it. The
  result is shown as a total for the unit.
- **Hiring.** An open position has a hiring status (not started, hiring, offer made, on
  hold) and a target start date. Both are planned. Where no date is set, the tenant's
  usual time to hire gives a forecast one. Cost starts on that date. Where a hiring
  system is connected it supplies the status.
- **Ramp.** A new hire delivers less at first. The capacity model states how long a hire
  takes to reach full capacity, and a step counts them at what they deliver in it.

A forecast appears as its own row for a unit and a step: in the cost table, under
capacity and in the headcount walk. It is never drawn as a person on the map.

Forecast promotions and pay increases draw on a pool, a budget line for promotions and
increases, and not on each position's own budget line. That is how organisations budget
them.

A planner who disagrees with a forecast changes the assumption. There is nothing to
dismiss person by person.

### Stay within the approved budget

The approved headcount budget is what an organisation has agreed to spend on people for a
period. It rarely maps one to one onto the teams and roles a plan ends up with, and the
budget is what matters: a plan is affordable when it fits the budget, however the budget
was traded to get there.

The budget is a set of **budget lines**. Each budget line records what was approved: a role, level,
location and cost centre, an amount, the period, and where it came from (an existing
employee, a replacement for someone leaving, a new hire approved on a given date). The organisation's
approved budget lines are the default every plan starts from. Like any other data, a scenario
can add, cut or change budget lines to try a different budget, and the plan shows how its budget
differs from the approved one.

Positions **draw on** budget lines. A filled position draws on its person's budget line. A backfill draws on the
departing person's. A new position draws on an approved budget line, on part of one, on several, or on nothing
yet. That gives every scenario the same four numbers, everywhere a total appears:

- **Approved**: the budget.
- **Funded**: what the scenario's positions draw from it.
- **Remaining**: approved budget nothing draws on.
- **Unfunded**: positions no budget line covers. This is the new money the scenario needs.

Nobody wires each position to a budget line by hand. The plan works out a default in two steps, and
shows its reason beside the position.

- **Which cost centre a position belongs to.** A filled position takes the cost centre its person
  has in the Org Graph. An open position takes it from **cost centre rules**: by unit ("every
  position in this unit draws on the unit's own centre"), by role ("product managers and
  designers draw on Product"), or by both together. The rules are an ordered list and the
  first match wins. They start from the tenant default and a plan or scenario can change
  them. A planner can also set a position's cost centre directly.
- **Which budget line it draws on.** The most specific budget line that matches the position's cost centre
  and period. A position funded any other way, from another centre or split across budget lines, is
  a trade.

When a plan moves a person, the rules may give their position a different cost centre from
the one on their record. The plan keeps costing them where their record says and flags
the mismatch. The planner resolves it by planning the cost centre change, which then
joins the changes to raise in the HRIS. A plan never assumes a change nobody has asked
for.

How strictly positions must follow budget lines is a rule of the scenario. It starts from the tenant
default and a descendant can change it:

- **Position control.** Every position must be backed by a budget line that matches it: same role,
  level and cost centre. A position that differs from its budget line is a variance to be approved,
  and the plan lists each one.
- **Envelope.** Only the total matters, for the organisation or per cost centre. A departing
  designer budget line can fund a product manager's parental-leave cover; two junior budget lines can
  fund one senior. The plan checks the sum and nothing else.
- **Between the two.** Many organisations hold both a money limit and a headcount limit,
  or allow trades inside a cost centre but not across. The rule is a setting: which
  dimensions must match (role, level, cost centre, location), and whether the limit is
  money, heads or both.

Whichever rule applies, a **trade** is explicit and stays visible: this budget line funds that
position, with a note. Under an envelope that is a record of how the budget was used; under
position control it is the list of exceptions someone must sign off. The standalone tool
had only the first half of this, as a ledger of backfills matched by name. Budget lines
replace it.

The budget is a **headcount** budget, and that is its whole scope. A cost centre is a
label to group by. Accounts, ledger codes and the rest of a finance system's identifiers
are not modelled.

A budget states its **basis**: fully loaded, meaning inclusive of on-costs, or base pay only. Positions are
measured on the same basis as the budget they draw on, and every total says which it is.
On-costs themselves come from an on-cost model, a flat rate, rates by country or itemised
components, chosen and changed like any other configuration.

Two further things fall out of treating the budget as its own object:

- **Variance.** A budget line approved at one amount and filled at another leaves a difference,
  shown per budget line and in total.
- **Budget changes over time.** A new approval or a cut is a dated change to the
  organisation's budget. Every scenario that has not overridden those budget lines is re-measured
  against it at once, and one that has is told its source moved.

### Measure delivery capacity

Capacity says how much a team can deliver, which headcount does not. How it is calculated
is a **capacity model**, and models are pluggable: the module ships with some and a
deployment can add its own.

The model we planned with counts in units. One unit is roughly what a solid mid-level
contributor delivers. The curve rises with level and then flattens: one principal is not
four juniors. Managing costs capacity, and the cost comes from the reporting graph: a
fixed part by the manager's level plus a part per report, scaled by distance and by how
junior the report is. An open manager position is charged for the span it will carry, so
leaving positions empty never flatters a scenario. That model suits engineering. Other
families may want plain fractions of a person, a count of cases or accounts carried, or
no capacity at all.

- **Chosen per role family, overridable per role.** A family picks a model and sets its
  parameters; a role within it can use different parameters or a different model. Like
  all configuration, the choice has a tenant default and a plan or scenario can change
  it.
- **Overridable per assignment.** The capacity a model calculates for a person in an
  assignment can be replaced with a specific number: someone ramping up, someone on a
  phased return, a lead who in practice codes half the time. The override is marked like
  any other, with the calculated figure shown behind it.
- **Shown with its working.** Capacity appears per unit and per scenario, and each
  person's figure opens to show how the model reached it.
- **Only like adds to like.** Totals are kept per model, so a team's engineering units and
  its design allocations are never summed into one number.

### See capabilities in the plan

This is what the standalone tool could not do.

- **Team profile.** For each unit, what its people demonstrate, capability by capability:
  where the team is deep, where it is thin, and where one person is the only one
  consistent at the level the work needs.
- **Fit for a position.** A position is a role at a level, so it carries expectations. A person
  can already be read against a role other than their own. Planning uses that reading to
  show who is close to an open position and what gap a proposed move opens or closes.
- **Intent.** A declared exploration of another role and the focus areas in a growth plan
  are signals a planner should see: the engineer exploring a management role when a
  manager position opens, the move that serves someone's growth as well as the roadmap.
- **Comparison.** A scenario's difference from the baseline includes capabilities: this
  team loses the only person consistent in a capability, that team gains depth it did not
  need.
- **Honest data.** Each reading shows how many people it rests on and how old their
  assessments are.

Capabilities inform composition. They do not change a person's capacity or cost: level
does that. A plan that turned ratings into output would make every self-assessment a
negotiation.

### Read the plan along the calendar

A scenario covers a period, and a fork says which of two things it is:

- **Then.** What happens next. The child starts where its parent ends. Periods along a
  path are contiguous: no gaps, no overlaps, no period nested inside another.
- **Instead.** What if. The child is an alternative to its parent over the same period.

A timeline is one path from the baseline to a leaf, read left to right, with one column
per step. An alternative is never an extra column; it is a choice at a step.

- **Lanes.** Units are blocks, with one lane per person or position. Moves are written where a
  person's bar ends and begins, and a replacement takes the lane of the person it
  replaces. A person can be followed from team to team across the whole plan.
- **Forks.** A step with alternatives shows a switch. Choosing one swaps that column and
  everything after it.
- **Compare two paths.** The steps they share are drawn once; lanes split only where the
  paths differ.
- **Where decisions live.** A bar carries the override mark in the column where the
  placement was explicitly set, and is plain where it is inherited. A change can be seen
  flowing rightwards and stopping at a pinned one.
- **Edit in time.** Dragging a person to another block in a column edits that step.
  Dragging the end of a bar moves the change a step earlier or later.
- **Totals under the columns.** Cost against budget, unfunded positions and capacity per step, so the
  trend reads along the same axis.
- **The headcount walk.** A lane of its own, drawn as a graph under the units: opening
  headcount, then hires, departures known and expected, and transfers in and out, down to
  closing headcount. It reads per step, for the whole plan or for one unit, and a closed
  step shows what happened beside what was planned.

For now an alternative's later steps belong to it alone: to see next half under both the
base case and a funded variant, the later step is built twice. The stored form must not
rule out the better answer, where an alternative is an overlay that can be switched on
over the main line and carries through every later step. It does not, as long as a change
records an end state for one subject and never refers to the content of its parent: the
same set of changes can then be applied over a different base by the update rules above.

### Keep up with reality

No plan survives contact with the organisation. People leave, hires land at another
level, a move happens a month late. Because every planned change is an end state measured
against the Org Graph, each one always has a status:

- **Done.** The Org Graph now matches it. It is no longer a difference, and the plan
  shrinks towards what is still to do.
- **Pending.** Not yet true. It is carried forward.
- **Conflicting.** The Org Graph went somewhere else: the person planned to move has left,
  the position was filled by someone other than planned. The change is kept, flagged, and
  waits for a decision: restate it, or clear it.

What the Org Graph did that the plan never mentioned simply arrives underneath, and the
ordinary checks catch anything it breaks.

How a change gets done depends on who holds the fact:

- **Facts another system holds** are done when the sync shows them. Nobody confirms them in
  Espalia.
- **Facts Espalia holds** are done when the planned change is applied to the Org Graph. This is
  the merge, and it is the only way a plan reaches the Org Graph. It is always a deliberate
  act by someone allowed to change the structure.

Approving a plan is the one process the module owns, and it is where a tenant's
guardrails become binding. Often only part of a scenario is agreed. It can be split into
the agreed part and the rest, without changing what anyone sees; the agreed part is
approved and everything that followed now follows from the rest. What was approved is fixed at that moment; a later edit is a
new difference. On approval, the changes Espalia holds are applied. For everything else
Espalia is the source for the implementation and no more: it serves the approved list of
changes, and a person or an agent raises each one in the system that owns it, with their
own authority there. Espalia can note that a change was raised. It never treats one as
done until the Org Graph says so.

HRIS teams map to units the way HRIS titles map to roles. A team name with no mapping is
shown for someone to map, never guessed. Where Espalia holds a finer structure beneath an
HRIS team, and the HRIS then moves the person to a different team, the finer placement is
a conflict like any other.

When a step's period ends, the next step stands on the Org Graph, not on what was planned.
Its own changes survive the update. Whatever was still pending in the passed step moves
into the next one, marked as carried over. The passed step stays as a record of what was
planned against what happened. On the timeline a line marks today: columns behind it show
what happened, with the plan drawn faintly where it differed.

### Check the plan

Checks warn; they do not block. A plan in progress is allowed to be wrong. A check that
comes from a tenant guardrail is marked as one, so a reader can tell the plan's own
inconsistencies from the organisation's rules.

- A person over- or under-allocated, or placed nowhere.
- A manager whose reports cost more capacity than they have.
- A descendant's change that no longer fits what its ancestors now say.
- A contributor whose manager shares no unit with them, or who has no manager at all.
- Positions that no budget line covers, a cost centre or the organisation over its limit,
  and, under position control, each position that differs from the budget line behind it.
- A budget line nothing draws on: remaining budget someone may want back.
- A filled position whose person's cost centre differs from what the cost centre rules give
  it; an open position no rule places; a position that two budget lines match equally well.
- A role nobody has classified for capacity.
- A person the plan places who has since left; a placeholder whose hire has arrived.
- A planned change the Org Graph now contradicts, and one carried over from a passed step.

### Share and discuss

The outputs are pages, not files: the team map with a scenario picker, the reporting
tree, the cost table, the timeline, the difference between two scenarios and the check
list. Each scenario carries a description of what it changes and why.

Every read and every change is an Operation, so the same plan can be worked through the
web or through an MCP client. Much of the planning this module is modelled on happened
that way: a planner talking a restructure through with an assistant that makes the
changes, runs the checks and reports what moved.

## Sensitive by default

A plan holds who might leave, who might move, where headcount goes and what it costs.

- A plan is private to the people named on it, each as editor or viewer. Being a tenant
  admin does not open someone else's plan. Nobody placed in a plan is notified.
- Capability readings follow the rule Espalia already applies to reports: a viewer never
  sees an aggregate built from assessments they could not open one by one. A team profile
  over five people is close to individual data, so the rule matters more here.
- Actual pay is a separate permission from seeing the plan. Without it, a viewer sees
  band midpoints only.
- Forecast promotions and pay increases are drawn from assessments, and are shown as
  totals that name nobody, under the cohort rule above. A member who could open a
  person's assessment can see that person's part of a forecast. Nobody else can.
- The organisation's approved budget and the tenant defaults are held by people permitted
  to hold them. A plan's changes to either stay in the plan.
- Data entered into a plan is as private as the plan. A salary pasted in from a
  spreadsheet is visible only to that plan's members who may see pay. It is encrypted
  under a key that belongs to the plan, as are notes and descriptions, and deleting the
  plan deletes the key.
- The module reads the roster. It never writes a fact to another system, and a plan by
  itself changes nobody's role, level, manager or team. Applying a planned change to the
  structure Espalia holds is a separate, deliberate act with its own permission.

## What the roster needs first

The sync brings in name, email, title, department, manager, level and status. Planning
also needs, per person: site and country (for the band), FTE and employment type,
and start date. Where the integration cannot supply one, a plan can hold it, so a missing
field never blocks planning.

Team structure varies most. Some HRISs hold team names and membership, and a few hold
positions; many hold neither. The module must work either way, level by level: the HRIS
supplies whatever structure it holds, and Espalia keeps the current structure
for the rest, authored once and then changed only by applying planned changes or by
direct edit.

## Later

- **Requests from managers.** A unit's owner asks for a new position or a backfill
  through a short form, without being a member of any plan. A planner accepts the
  request into a scenario or declines it with a reason. It builds on the editing rights
  the Org Graph already gives a unit's owners.

## Not in scope

- Being the system of record for anything an integration holds. Espalia holds only the
  facts no integration supplies, and yields them when one does.
- Writing facts to another system, or running its processes. Espalia approves a plan and
  serves the list of changes; the owning system's own workflow carries each one out.
- Payroll, offers or compensation review.
- Ranking people. Capabilities appear as team profiles and position fit, never as a league
  table.
- Scoring a roadmap. Capacity in unit-weeks is the join a roadmap would use, and the
  module should expose it. Ranking initiatives against it is a later module.

## Terms

The module uses the words workforce planning already has. These were chosen on purpose;
keep to them in the product, the events and the documents.

| Term | Meaning | Not |
|---|---|---|
| Position | A role at a level in a unit, filled or open. | Seat |
| Open position | A position nobody holds: a backfill or a new position. | Vacant seat |
| Budget line | One approved piece of the headcount budget. Always written in full, because "line" alone also means a reporting line. | Line |
| Approved, funded, remaining, unfunded | The four budget numbers. | Headroom, the ask |
| Cost centre rules | The ordered rules that give an open position its cost centre. | Allocation rules |
| Allocation | A person's share of a position or unit. | Fraction |
| FTE | How much of full time a person or position is. | Employment fraction |
| Band midpoint | The price of a position when pay is not shown. | Band price |
| Done, pending, raised, conflicting | A planned change against the Org Graph. | Landed |
| Update to today | Reading a plan over the Org Graph as it is now. The design documents call the mechanism a rebase. | Rebase, drift |
| Fully loaded, base pay | The two bases a budget can be stated on. On-costs are what separates them. | |
| Departure | Someone leaving. | Leaver |
| Actual, planned, forecast | Where a figure comes from: the Org Graph, a decision in a scenario, or an assumption. | Known, projected |
| Committed, all positions | The two views of a total: without new positions that have no committed budget, and with them. | Planned, for this switch |
| Expected attrition | Departures a plan assumes from a rate, with nobody named. | |
| Ramp | The time a new hire takes to reach full capacity. | |
| Headcount walk | Opening headcount, the movements in a step, and closing headcount. | |

Org Graph, unit, guardrail, trade and step are the module's own words. No single industry
term covers them.
