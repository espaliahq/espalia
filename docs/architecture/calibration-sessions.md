# Calibration Sessions — Design

> **Status: V1 shipped** (scope agreed 2026-07-24: facilitator-only access,
> value-free revisit requests, own event stream). What follows is the design
> record; the code is the source of truth for detail.
>
> **Built.**
> *Domain* — `CalibrationSession` aggregate + projection + cycle-close sync;
> every write through `Operations::CalibrationSessions::*` (web + MCP);
> `CalibrationSessionPolicy`; `PopulationSeeds`.
> *Setup* — list / define / draft curation / readiness / start / close, with
> the shared `Views::Shared::PersonPicker` typeahead for participants.
> *Overview* — rater-tendency strip + capability-divergence board
> (`OverviewStats`, `calibration_sessions_overview`) + draft-phase agenda.
> *Drill-in* — expectation text with role illustrations, the rater × level
> dot grid, and a three-pane bottom half (person card / evidence wall §d /
> compare tray §e). See *Drill-in implementation notes* under §3.
> *Outcomes* — ⚑ expectation flags raising a framework **clarification**
> (the non-proposal suggestion kind, framework-explorer.md §12a); **revisit
> requests** mirrored onto the PD stream (`CalibrationRevisitSync`),
> surfaced in the rater's assessment feed and notified
> (`RatingRevisitNotifier`, dropped if already acted on), resolved by
> rating-change at read time; **session notes**.
> *Follow-through* — the session log, rendered as a right-hand activity
> side panel on both the session page and the drill-in.
> *Dev data* — `assessments:seed_calibration_activity` gives every surface
> demo-able population-wide activity.
>
> *Provenance* — carried-forward (seeded, unconfirmed) ratings are marked
> on every read surface; see *Carried-vs-vetted provenance*.
>
> **Not built** (each has its own section below):
> auto-suggested contrast pairs (§e) · evidence requests as a session
> outcome (§f) · participant follow-along + the v2 visibility grant ·
> cross-cycle trends · MCP reads for the drill-in surfaces
> (*Cross-cutting*) · in-surface definitions for the calibration vocabulary
> (*Deliberately deferred*).
>
> **Known display nit:** raters with identical means on a capability render
> exactly-overlapping dots on the divergence board (the tooltip and the aria
> summary still carry both).
>
> Read alongside [assessments.md](../guidelines/assessments.md),
> [scoring-model.md](scoring-model.md), and
> [event-sourcing.md](../guidelines/event-sourcing.md).

## Purpose

A calibration session lets a manager of managers (the **facilitator**) sit down
with a set of **participants** (the raters — e.g. a department head with their
EMs) and compare how each of them rates their reports against the framework's
behavioural expectations. Two explicit goals:

1. **Surface unclear behavioural expectations** — inconsistent ratings across
   raters often mean the expectation *text* is ambiguous, not that the people
   differ. These findings feed the framework's existing suggestion machinery.
2. **Calibrate the raters with each other** — converge on a shared reading of
   what each frequency means at each level, so ratings are comparable across
   teams.

Sessions can be run at any scope — a department's EMs, the whole org's
managers, a custom set — and the **same people may be calibrated in multiple
sessions within one cycle** (department session first, org-wide roll-up after).

## The unit of calibration

The thing being calibrated is the **behavioural expectation (capability ×
level)** — the canonical rated unit — not "how a manager rates" in the
abstract. Two consequences:

- **Raw frequencies across people at different levels are apples-to-oranges.**
  The overview compares raters on their **at-level** ratings only (each
  person's cell at their own assessed level, on the equal-interval 0–3
  frequency scale — `OverviewStats::FREQUENCY_VALUES`, deliberately NOT
  `Scoring`'s contribution weights: calibration compares raters on an
  ordinal scale, not scoring contribution); the drill-in groups by level so
  same-level people are compared directly against the level's expectation
  text.
- **Two failure modes must stay visually separable**, because their remedies
  differ:
  - **Rater tendency** — an EM is systematically lenient/harsh across all
    capabilities → coaching conversation.
  - **Expectation ambiguity** — one capability shows high between-manager
    spread while the managers are otherwise consistent → the expectation text
    is the problem → fix the framework.

  The separation is cheap: per capability, compare between-manager spread of
  mean ratings after subtracting each manager's overall tendency offset. A
  capability that stays divergent after the correction is an
  "unclear expectation" candidate. The UI surfaces the ranked list, never the
  statistics.

## Domain model

### Aggregate and stream

A new event-sourced aggregate with **its own stream**:

```
tenant-{tenant_id}/CalibrationSession-{session_id}
```

It lives in the **assessment_cycles bounded context** — calibration is cohort
activity, and the cycle is its conceptual owner — but it does NOT share the
cycle's stream. Reasons this is load-bearing:

- **Cardinality + contention.** One cycle hosts many sessions, possibly
  running concurrently (Engineering and Product calibrating the same
  afternoon), and session events are chatty (notes, flags, revisit requests).
  Interleaving them on the cycle stream would contend on optimistic
  concurrency for unrelated writes and make every cycle command replay
  hundreds of session events forever. The cycle stream stays sparse.
- **No shared invariant.** Session invariants (population rules, lifecycle
  gating) are session-local; cycle invariants never consult session state.
  Different consistency boundaries ⇒ different aggregates.
- **The house pattern for "related but distinct lifecycles" is small streams +
  sync handlers** (`PersonEnrollmentSync` is the template), not co-located
  streams.
- **Optional cycle coupling.** The session carries `cycle_id` as a reference
  on its definition event. Ad-hoc calibration outside a formal cycle stays
  possible later without remodelling.

### Lifecycle

```
draft ──▶ started ──▶ closed
  │  participants + population editable
  │
  started: both sets FROZEN (snapshot carried on the event — the ADR-19
           enrollment-snapshot instinct: mid-session org changes must not
           reshuffle the room or the denominators on screen)
```

- **Cycle close auto-closes open sessions** via a sync handler subscribed to
  the cycle's close event — same section of the RES initializer as the other
  cross-stream sync handlers, and like them it MUST NOT be registered as a
  replayable projection.
- A stale-session guard (auto-close after a horizon, or a sweep job) prevents
  a forgotten session lingering open indefinitely. Matters more in v2 when a
  live session implies visibility grants.

### Events (sketch)

| Event | Phase | Notes |
|---|---|---|
| `SessionDefined` | — | facilitator, participants, seeded population, `cycle_id`, framework version |
| `ParticipantAdded` / `ParticipantRemoved` | draft | adding a participant who is currently a calibrant auto-removes them from the population |
| `CalibrantAdded` / `CalibrantRemoved` | draft | manual population curation |
| `SessionStarted` | draft→live | freezes participants + population (snapshots on the event) |
| `AgendaItemDiscussed` | live | walk-through progress |
| `ExpectationFlagged` | live | capability × level + reason; carries the `suggestion_id` of the framework clarification it raised (see Outcomes → *The clarification kind*) |
| `RatingRevisitRequested` | live | person × capability × level + discussion note; mirrored to the PD stream (see Outcomes) |
| `EvidenceRequestRaised` | live | records that a cell-scoped evidence request was fired from the session (the request itself rides the existing machinery) |
| `NoteRecorded` | live | free-text minute, anchored to capability or person |
| `SessionClosed` | live→closed | facilitator action or cycle-close sync |

All writes dispatch through `Operations::*` classes (web + MCP parity, audit
metadata, the house rule).

### Read models

A session projection owning its own tables (session header, population
membership, agenda state, outcomes). Per the read-model ownership invariant it
never writes to any other projection's tables; everything it displays about
ratings/evidence is a **read-time join** against `AssessmentLevelRating`,
`PersonFrameworkAssignment`, `RecordedReportingManager`,
`AssessmentCycleProgress`, and the evidence read models.

## Population rules

- **Seeded, then curated.** At definition, the population seeds from the union
  of each participant's reports — "Team Assessments" semantics: recorded
  reporting manager (authoritative) plus active rating delegations, i.e.
  exactly the ratings each participant owns and can defend.
- **Curation in draft only.** The facilitator may add anyone from their own
  org subtree (`Person#managed_by?`, policy-enforced at command time, not
  filtered client-side) and remove anyone. Removals are restorable while in
  draft.
- **Seed once, never silently re-derive.** A curated list must not mutate
  behind the facilitator's back on re-org. A "refresh suggestions" affordance
  surfaces *"2 new people report to Raj since you defined this — add them?"*
  as an explicit choice.
- **Participant exclusion is an aggregate invariant:**
  `population ∩ participants = ∅`, facilitator included. Adding a calibrant
  who is a participant is rejected; participants excluded from the population
  render in setup as visible-but-disabled entries ("excluded: participant in
  this session") so the absence always reads as deliberate. Participants'
  own calibration happens in a separate session where *their* manager holds
  the room.
- **Freeze at start.** Every divergence statistic on screen depends on the
  population; a mid-discussion add would silently reshuffle numbers the room
  just argued about. Mid-session "we should look at X too" becomes a session
  note ("add X to the org-wide session"), not a mutation.

### Raters who aren't in the room

Because anyone in the facilitator's subtree can be added, the population can
include people whose rater is **not a participant** — e.g. reference people
from a sibling team added as anchors (a legitimate calibration technique), or
recently re-org'd reports. Their data stays visible (reference points are the
point), but their rater's row is **visually muted ("not in session")** and:

- excluded from the rater tendency strip — you can't calibrate someone in
  absentia, and their appearing to "skew high" with no right of reply poisons
  the session;
- exempt from outcomes — no revisit requests against a rater who isn't
  present to hear the discussion.

## Access model — facilitator-only (v1)

Only the facilitator loads the session pages; the room views a projected /
screen-shared display. The facilitator is an ancestor of the entire population
(subtree-scoped adds guarantee it), so existing `AssessmentPolicy`
chain-visibility already admits every read. **Zero authorization changes.**

- **The room sees who it is discussing** — see *Naming* below.
- Session `create` is gated on "manages managers in own subtree" or tenant
  admin.

### Naming — the room sees who it is discussing (resolved)

The drill-in **names everyone**: a dot carries the ratee's initials as its
compact label plus their full name (tooltip + accessible name), the person
card and compare cards name them outright, and evidence-wall items show the
author and the text.

> **Superseded (2026-07-29).** V1 shipped an anonymisation layer —
> anonymous-by-default dots, reveal-on-interrogation, sticky per person,
> with a session-level "Show names" override
> (`calibration_reveal_controller`). It has been **removed entirely**, along
> with its controller, its state and its toggle.

Why it went, since the reasoning is worth keeping for anyone tempted to
reintroduce it:

- **It never was privacy control, and it stopped being choreography.** Access
  control was already solved (facilitator-only; Pundit ran before anything
  rendered), and it was never secrecy — every dot's rater is in the room,
  grid position often uniquely identifies ("Raj's only L5"), and evidence
  bodies name projects that name people. Its one claim was *choreography*:
  make the room debate the standard before the individual.
- **The grid has to be discussable.** A wall of unlabelled dots can't be
  pointed at ("which one is that?"), so the dots gained initials — and in a
  room of six, beside a named rater column, initials identify people. What
  remained was the *appearance* of anonymity over data that no longer was.
- **Half-anonymity costs more than it buys.** Two vocabularies (revealed /
  unrevealed), a sticky client-side state, a wall that hid its own content
  behind a placeholder, and a per-person reveal set threaded through the
  frame swaps — all to delay a name the room could already infer.

What replaces it is the ordinary discipline the rest of the product uses:
the facilitator is an ancestor of the whole population, so they were always
entitled to every name on screen; the session is a projected working
surface, not a publication. If a room wants to debate the standard before
the person, the **divergence board** — which is aggregate by construction —
is the surface for that, and it comes before the drill-in by design.

### V2 path — session-scoped visibility grant (documented, deferred)

Participant follow-along on their own devices requires a horizontal,
temporary read grant (an EM reading a sibling team's ratings). The design,
when wanted, is the `ManagerAssessmentDelegation` pattern reused:

- The grant is **derived from session lifecycle events** (`SessionStarted` =
  grant, `SessionClosed` = revocation) — no separate grant command; a
  projection materializes `(session, participant, calibrant, window)` with an
  `active` scope; a policy predicate (`active_calibration_co_participant?`)
  consults it.
- **Narrow scope, firmly:** the grant unlocks the *session surfaces only*
  (gated by a `CalibrationSessionPolicy`), never `AssessmentPolicy#show?`.
  Participants see the deliberate calibration slice — manager ratings,
  deltas, evidence excerpts — not the full assessment page (self-ratings,
  comment threads, alignment state stay out; individual self-ratings remain
  facilitator-only even in-session).
- Open org-norm question for that increment: whether the assessee is ever
  told out-of-chain managers viewed their ratings in calibration. The grant
  is evented (auditable) either way; user-facing disclosure is a culture
  decision to make deliberately, not default into.

## Surfaces

All session surfaces are desktop/projector-first (no mobile pass — it is a
projected surface), but still carry system-test coverage per testing.md.

### 1. Setup / prep (facilitator, async, before the meeting)

```
Calibration session — Engineering · H1 2026 cycle

Participants (raters)        Population (23)                    [+ Add person]
  Mia  · 6 reports             ▾ Mia's reports (6)
  Raj  · 5 reports             ▾ Raj's reports (5)
  Sam  · 7 reports             ▾ Sam's reports (7)
  Ana  · 5 reports             ▾ Ana's reports (4)   1 removed
                               ▾ Added individually (1)
  Excluded automatically:         Priya N. (L4 · reports to Kim — not in session)
  Mia, Raj, Sam, Ana
  (participants)               Readiness: ▓▓▓▓▓▓▓░░ 19/23 manager-rated  [View gaps]

Suggested agenda (auto-generated, drag to reorder):
  1. ⚠ Strategic Thinking      — high EM disagreement, concentrated at L4
  2. ⚠ Technical Communication — Raj rates 1.2 bands below peers
  3. ○ Delivery                — broad spread, likely real team variance

                                              [Save draft]  [Start session]
```

- **Readiness gate** reuses `assessment_cycle_progress.manager_completed_at`:
  under-rated assessments are listed per EM with a nudge affordance. The
  facilitator can proceed anyway (real sessions run on imperfect data) but
  under-rated people carry a low-confidence badge in every view. Population
  members not enrolled in the cycle at all are flagged the same way.
- **Auto-agenda** ranks capabilities by residual between-manager divergence
  (tendency-corrected), each with a one-sentence plain-language reason.
  Facilitator reorders or removes freely.
- **Timing nudge**: calibration is most valuable after manager ratings are
  complete but *before* alignment starts (ratings can still move). Setup warns
  when participants' reports have entered `aligning`/`aligned` (individual
  ratings frozen — a revisit request against them can't be acted on until
  re-opened).

### 2. Overview — "where are we inconsistent"

**Rater tendency strip** — one row per participant; the "acknowledge our
biases first" moment. Aggregates only, never individual self-ratings:

```
            reports   vs. org mean      distribution     self-gap   evidence
  Mia          6        +0.4 ▲       ▁▂▅█  (skews high)    −0.1       21%
  Raj          5        −0.6 ▼       █▅▂▁  (skews low)     −0.8 ⚠     90%
  Sam          7        +0.1         ▂▅▅▂                  +0.1       55%
  Ana          5        −0.1         ▂▆▄▁                  −0.2       48%
```

- **self-gap** = mean(manager rating − self rating) across the EM's team — an
  independent bias signal (an EM far below their whole team's self-perception
  is either the room's only honest rater or has a calibration problem;
  either way, that's the conversation).
- **evidence** = % of the EM's current-level ratings backed by ≥1 active
  evidence link (see the evidence section). Leniency and substantiation are
  different axes: "Raj rates low but backs 90%; Mia rates high on 21%
  backing" reframes the discussion.
- **Small-n honesty:** show `n` everywhere; suppress ⚠ badges below a floor
  (n < 3) rather than pretending the signal is real.

**Capability divergence board** — one row per capability, per-EM mean as
positioned dots on a shared axis, sorted by spread; click → drill-in:

```
  Strategic Thinking    Raj●      Ana●        Sam●   Mia●     spread 1.8 ⚠
  Tech Communication         Raj●   Ana● Sam●  Mia●           spread 1.1
  Delivery                        ●●● ●                       spread 0.4
```

### 3. Capability drill-in — the core session surface

```
┌────────────────────────────────────────────────────────────────────┐
│ Strategic Thinking                          [⚑ Flag expectation]   │
│ L3: "Identifies root causes and weighs trade-offs…"                │
│ L4: "Shapes team direction by connecting work to strategy…" ⚠      │
│ L5: "Sets multi-team technical direction…"                         │
├────────────────────────────────────────────────────────────────────┤
│         L2        L3          L4            L5                     │
│  Mia    ·◍        ●●          ●◌ ●                                 │
│  Raj              ●●          ◌ ●●                                 │
│  Sam    ●         ● ●◌        ●●            ●                      │
│  Ana              ●●          ●◌ ●                                 │
│  Kim ⚪ (not in session)       ●                                    │
├────────────────────────────────────────────────────────────────────┤
│ [Person: Priya N.]  [Evidence wall]  [Compare (2)]                 │
│  …selected-tab content — see "Evidence & feedback in the session"… │
└────────────────────────────────────────────────────────────────────┘
```

- **Rows = raters, columns = levels** (not frequency buckets) — the question
  in the room is "is Raj's L4 *Some* the same behaviour as Mia's L4
  *Consistently*?", answered against the L4 expectation sentence directly
  above. Divergence is thereby localized to the level whose expectation text
  may be at fault.
- **Dot color = manager-rated frequency** from the existing
  `FrequencyPalette` — the vocabulary everyone already knows from the
  assessment screen. **Dot fill = evidence backing** (● backed / ◌ unbacked —
  see below).
- **Prior calibration context** (overlapping sessions): a small marker on
  dots already discussed in an earlier session this cycle, with the outcome
  on hover — "discussed in Engineering calibration July 10 — revisit
  requested, rating since revised Some → Most". This makes a later org-wide
  session a roll-up, not a blind re-litigation. Read-time join across session
  read models; sequencing between sessions stays social, never enforced.

#### Drill-in implementation notes

Things that bite when changing this surface:

- **The bottom pane is a Turbo Frame** (`calibration-pane`). Every pane link
  — a dot, a tab, a pin, an unpin, the wall's filters — differs from the
  current URL only by query string, so as full-page links they scrolled the
  room to the top and hid whatever was just opened. The controller swaps the
  frame and pushes the URL separately, so deep links and Back still work.
- **Anything rendered OUTSIDE that frame freezes at page-load state.** The
  grid's dots, the ⚑ flag form and the log panel's note composer all carry
  pane state (pins, filters, the opened person) that goes stale the moment
  the frame swaps. They opt into having the live values merged back in at
  click/submit time — `data-pane-keep-state` for links,
  `calibration-pane#stampState` for forms. A new link or form here needs the
  same treatment or it will quietly resurrect state the room cleared.
- **The room sees names** — dots carry initials as a compact label plus the
  full name in tooltip and accessible name; there is no anonymisation layer
  (see *Naming*).
- The **rater column is sticky-left**, so a sideways scroll on a narrow
  viewport can't orphan a row of dots from the rater they belong to.
- **Role illustrations** sit under each level's expectation behind the
  evidence dialog's shared "Examples (N)" disclosure, scoped to the roles
  actually being calibrated *at that level* — a framework carries
  illustrations for every role and the rest is noise.
- **The session log rides this page** as the same right-hand side panel the
  session page uses, defaulting closed here (the grid wants the width). It
  is deliberately skipped for pane-frame requests: the page re-renders
  server-side on every pane swap but Turbo keeps only the frame, so building
  the log would buy an unbounded stream read per dot click.

## Evidence & feedback in the session

> Surface labels follow the house terminology rule: users see
> **"Feedback / Evidence"**; the domain vocabulary stays `evidence`.

Calibration converges when the room stops trading adjectives and starts
comparing observed behaviour. "What did you actually see?" is the method —
and GrowthOS already stores exactly that artifact: evidence items linked
per (capability × level) cell, each link carrying a **valence**. The session
surfaces evidence at four altitudes:

### a. Backing signal on every dot (grid altitude)

Each dot renders **filled when the cell has ≥1 active evidence link, hollow
when unbacked**. This is deliberately pre-attentive: before any discussion,
the grid shows whose ratings rest on recorded observation and whose on
impression. The pattern-level read — an EM whose *high* ratings are
systematically hollow — is one of the most actionable calibration findings
and costs nothing to compute. (Fill ≠ color: color stays the frequency
palette; backing is shape/fill, so the two signals never compete. This
follows the level-chip precedent — content indicators are a separate visual
language from the rating language.)

### b. Evidence coverage per rater (tendency-strip altitude)

The strip's `evidence` column (above) aggregates the same signal per EM.
Substantiation is an axis of rater quality independent of leniency.

### c. Person card (dot click)

The selected cell's evidence, full-width in the drill-in's bottom pane:

```
Priya N. · L4 · rated by Raj          Mgr: ◼ Some   Self: ◼ Consistently  gap ⚠
─────────────────────────────────────────────────────────────────────────────
 ▸ [Demonstrates]         "Led the pricing re-architecture across three
                           squads; wrote the strategy memo that…"
                           peer feedback · linked by Raj · May 12
 ▸ [Strongly demonstrates] "Drove the platform consolidation decision…"
                           requested from T. Okafor · linked by Priya · Jun 3
   ⚠ evidence valence and rating point in different directions
─────────────────────────────────────────────────────────────────────────────
 2 items · 1 proactive, 1 requested          [Request evidence…]  [Pin to compare]
```

Card contents and rules:

- **Valence badge first** (`Views::Evidence::Valence` vocabulary — emerald /
  amber / rose, never the frequency palette: red/yellow/green/blue means
  *ratings*), then the excerpt, then provenance — author *relation* +
  linked-by + date + requested/proactive.
- **Valence↔rating coherence flag.** When the strongest linked valence
  contradicts the rating — *Strongly demonstrates* under a *Some*, or
  *significant growth area* under a *Consistently* — the card carries a quiet
  ⚠ "evidence and rating point in different directions". This is precisely a
  calibration conversation ("the evidence says more than the rating does —
  what else did you see?"), computed read-time from data that already exists.
  It is a discussion prompt, **not** a scoring input (ADR-10 stands: valence
  never feeds scoring).
- **Manager vs self split** rendered with the same diagonal-split vocabulary
  as level chips — the viewer-familiar "contested" signal.
- **Author identity is relation-first in session views.** The card shows
  "peer feedback" / "manager" / "self" / "requested from …" rather than the
  author's name — and, unlike the ratee's name, this one has NOT been
  dropped (see *Naming*): who is being discussed is the room's business,
  who wrote the feedback is not. Rationale:
  the facilitator is entitled to author names under `EvidencePolicy`, but the
  projected room is a wider *practical* audience than the policy
  contemplates, and peers wrote frank feedback under the existing visibility
  disclosure ("assessee, their managers, workspace admins") — not "a room of
  EMs". Relation preserves the calibration value (peer vs manager vs self
  weighting) at much lower exposure.
- **Comment threads stay out of session surfaces entirely (v1 decision).**
  Cell threads and evidence-linkage threads are conversational, often blunt,
  and linkage threads exclude even the evidence author by design — projecting
  them is a category error. The facilitator can open the person's full
  assessment in another tab when genuinely needed.

### d. Evidence wall (capability altitude — the norming surface)

A drill-in tab showing **all evidence linked to this capability across the
population**, grouped by level, each item stamped with the frequency its cell
carries:

```
[Evidence wall — Strategic Thinking]                filters: [level ▾] [valence ▾] [rater ▾]

  L4 ──────────────────────────────────────────────────────────────
   ◼ Consistently · Mia's report   [Strongly demonstrates]
     "Drove the platform consolidation decision, aligning four teams…"
   ◼ Some · Raj's report           [Demonstrates]
     "Led the pricing re-architecture across three squads; wrote the…"
   ◼ Most · Sam's report           [Demonstrates]
     "Owned the quarterly planning narrative for the group…"
  L3 ──────────────────────────────────────────────────────────────
   …
```

This is where goal #2 actually happens. Reading down a level column, the room
sees what behaviours *each rating grade was actually awarded for* across
teams — and the money shot is two near-identical pieces of evidence under
divergent ratings from different EMs. That juxtaposition is the calibration:
either the ratings converge, or the expectation text gets flagged, or both.
The wall makes the comparison ambient instead of requiring the facilitator to
hunt for it dot by dot.

- Each wall item names its person and shows what was written (see
  *Naming*).
- Unbacked cells don't appear on the wall by definition — the hollow dots in
  the grid remain their signal.

### e. Compare tray (the deliberate juxtaposition)

The facilitator pins 2–3 person-cards (e.g. same capability, same level,
different raters, divergent ratings, both backed) into a side-by-side tray —
the "why is this a *Some* here and a *Consistently* there?" artifact,
composed deliberately rather than scrolled past. V1 is manual pinning;
auto-suggested contrast pairs (similar level + divergent rating + both
backed) are a natural later increment once the manual gesture proves out.

### f. Missing evidence as an outcome — NOT BUILT

> The only part of the evidence design still outstanding. The person card
> mock in §c shows its `[Request evidence…]` affordance; neither it nor
> `EvidenceRequestRaised` exists yet.

When a disputed cell is unbacked and the room can't answer "what did you
see?", the resolution *is* an evidence request. The person card's
**[Request evidence…]** rides the existing cell-scoped request machinery
(`Operations::Assessments::RequestEvidence` — modal with candidate
suggestions, shared reason, due date), fired by the facilitator. The session
records an `EvidenceRequestRaised` event referencing the request so the
follow-through page can track it; the request itself lives where evidence
requests already live (the hub, reminders, the response flow — nothing new).

### Data notes

Everything above is read-time over existing read models (`EvidenceItem`,
`EvidenceLink` + valences, per-cell like the assessment screen reads them).
The only evidence-related *write* from a session is (f), which is an existing
operation. No new evidence tables, no projection changes.

## Outcomes

A session that produces only conversation evaporates. Four outcome types, all
session-stream events dispatched through Operations, three of which route
into existing machinery:

1. **⚑ Flag expectation as unclear** → raises a framework **clarification**
   — a new non-proposal suggestion kind (see *The clarification kind* below,
   the resolved design). Independent flags from multiple sessions stack
   exactly like multi-author suggestions already do — and "flagged
   independently by Engineering *and* Product" is itself strong evidence the
   text is the problem. Goal #1 becomes a pipeline into the framework's
   improvement loop, not an exported report.
2. **Ask a rater to revisit a rating** → a **value-free** nudge (discussion
   note attached, never a suggested target rating), mirrored onto the
   person's PD stream by a sync handler (the `PersonEnrollmentSync` shape) so
   it surfaces in the rater's assessment activity feed where they work. The
   rater owns the rating and revises it through the normal flow.
   - *Why value-free is structural, not just polite:* with overlapping
     sessions, a department room recording "consensus: *Most*" and an
     org-wide room later recording "consensus: *Some*" manufactures a
     contradiction the EM must arbitrate. Notes compose across any number of
     sessions; target values don't.
   - *Provenance + resolution:* the PD-side event carries
     `calibration_session_id`; resolution is **rating-change-based** — when
     the rating is revised, every open revisit request against it resolves at
     once ("flagged in 2 calibration sessions" is one coherent signal, not
     two tickets).
3. **Request evidence** for an unbacked disputed cell (see evidence §f).
4. **Session note** — free-text minute anchored to a capability or person,
   rendered as a feed on the session page.

**The closed session page is the follow-through artifact**: agenda covered,
flags raised (with live links to the resulting framework clarifications and
their status), revisits requested vs. acted on, evidence requests fulfilled.
It is the opening slide of the next session ("last time we flagged 3
expectations — 2 were rewritten").

### The clarification kind — widening the suggestion model (resolved design)

The ⚑ flag exposed a fusion inside the suggestion system: a suggestion is
**an anchored, lifecycled discussion** AND **a concrete proposal applied on
approval** — every existing kind (edit / create / delete) happens to be a
proposal, so the fusion was invisible. Calibration needs the first half
without the second: a discussion anchored on capability × level that may
resolve into a rewording, better illustrations, or "the text is fine, here's
the reading" — but proposes nothing itself. The resolution is to **widen the
suggestion model with a non-proposal kind, `clarification`**, rather than
bend proposal semantics (a placeholder proposal whose approval is a no-op)
or replicate the discussion machinery. The user-level framing: *"this is a
suggestion thread, just not of a specific outcome."*

Mechanics — everything not listed here is inherited untouched:

- **One new framework-stream event** (`ClarificationRequested`), projected by
  `PublishedState` into the SAME `framework_suggested_edits` table with
  `kind: "clarification"` and a **nil `suggested_value`** — the presence
  validation becomes conditional on kind (it was always a proposal-kind
  rule). Additive event, no `CODE_VERSION` bump.
- **Thread machinery: zero changes.** Comment events, the `SuggestionThread`
  projection, `framework_suggestion_comments`, the Thread/CommentCard views,
  the `comments-thread` Stimulus contract, and both comment policies all key
  off `suggestion_id` and are indifferent to whether the anchor proposes
  anything.
- **Feed + pane: the existing rails.** Clarifications surface as suggestion
  entries with the discussion affordance and open the same suggestion card.
  They sit OUTSIDE `ActivityFeedQuery::PROPOSAL_KINDS` (the codebase already
  distinguishes proposal-only logic) and render no inline diff (nothing is
  proposed).
- **Resolution verbs differ — that is the whole delta.** No approve/reject:
  a clarification is **resolved with a note** ("reworded L4 — see suggestion
  …", "added two illustrations", "wording is fine; here's the reading"),
  optionally carrying a `resulting_suggestion_id` linking the concrete change
  it spawned. `withdraw` stays for author retraction. The §12 actionable-feed
  pattern parameterizes: inline action "Resolve" (modal for the note), gated
  by the same expectation-tier authority
  (`SuggestionApprovalAuthority#can_approve?("behavioural_expectation")` —
  whoever could change the text can declare the question settled).
- **Anchoring**: the expectation entity when one exists at the cell (that IS
  capability × level, and focus filtering/navigation already resolve its
  coordinates); for a cell with no expectation ("nothing defined here" being
  the complaint), anchor the capability and carry `level_ordinal` in
  `proposed_attributes`.
- **Matrix decoration: a comment glyph, edit mode only (decided).** The
  affected cell carries a small **speech-bubble glyph** — the same content
  language the assessment level chips use for comments — signalling at a
  glance that a relevant discussion exists; zooming in (cell focus / the
  pane) reaches the clarification card. Deliberately NOT the amber wiggle:
  the wiggle means "differs from published", and a clarification proposes no
  change. Glyphs are shape, not colour, so they never compete with the
  pending-edit vocabulary. View mode stays clean (published state only, per
  the explorer's mode rules). Fed from the same single-pass
  `build_suggestions_map` aggregation, with clarifications excluded from the
  diff/`latest_by_field` payloads. Capability-anchored (no-expectation)
  clarifications put the glyph on the capability row instead.
- **Calibration wiring**: `Operations::CalibrationSessions::FlagExpectation`
  authorizes as the **session facilitator** (who may hold no framework
  collaborator role — deliberate: the flag is raised on the session's
  authority), dispatches the frameworks `request_clarification` command with
  an auto-composed rationale carrying the session context ("flagged during
  Engineering calibration — raters diverged 2.0 bands beyond tendency"),
  then records `CalibrationExpectationFlagged` on the session stream with
  the resulting `suggestion_id`. Two streams, not atomic — framework write
  first; the failure modes are benign. The follow-through page reads flag
  status via that stored id.
- **Naming note — done**: the "suggestion = anchored discussion with a
  lifecycle, proposals are the applying subset" framing is now stated in
  framework-explorer.md **§12a**, which is the canonical reference for the
  clarification kind's mechanics.

## Overlapping sessions — semantics

- **Sessions are forums, not owners.** No session has exclusive claim over a
  person or rating; population membership is a snapshot, never a serialized
  invariant. Overlapping sessions run concurrently with zero cross-stream
  coordination.
- **Prior-session context is read-time** (drill-in markers, overview
  "previously calibrated" badges) so later sessions roll up rather than
  re-litigate.
- **Ordering is social.** Nothing enforces "departments before org-wide";
  the history surface makes ordering visible and useful without making it
  mandatory.
- The cycle's session list carries a light scope label (org-wide /
  department / custom) so the ladder is legible.

## Cross-cutting

- **MCP** (Operations-first, house rule): reads
  (`calibration_sessions_list`, `calibration_sessions_get`,
  `calibration_sessions_overview`) as `:none` ops scoped by the same
  facilitator policy — "where are my EMs most inconsistent?" is a genuinely
  good agent query.
  **Deferred deliberately: the drill-in's own reads** — the dot grid, the
  evidence wall, the compare tray and the session log have no MCP tools.
  They are read-time compositions of data MCP already exposes per person
  (`assessments_evidence_list`, `assessments_capability_get`), and the whole
  calibration read surface wants exposing as one considered increment rather
  than view by view. Every calibration *write* already has a tool.
  Define + population
  curation are `:mcp_client` (draft-phase, freely reversible); **start and
  close are `:in_app`** (start locks the room's denominators, close is
  terminal — the cheat sheet's lock/irreversible rows). Flags, revisit
  requests, notes `:mcp_client`. The clarification kind adds framework-side
  tools too: `frameworks_request_clarification` and
  `frameworks_resolve_clarification` (both `:mcp_client`, matching the other
  suggestion-lifecycle ops).
- **Activity feed coverage**: session outcomes surface in the feeds that
  already exist — expectation flags in the *framework* feed (via the
  suggestion machinery), revisit requests in the *assessment* feed (via the
  PD mirror event; register the kind + `KIND_GROUP`, broadcast per the
  real-time rule). The session's own page carries its session-log feed.
- **Authorization**: `CalibrationSessionPolicy` — `create?` = manages
  managers in own subtree or tenant admin; `show?`/drive = facilitator (or
  tenant admin) only in v1. Policy tests per testing.md (non-member /
  member / participant-EM / facilitator / admin matrix — note participant
  EMs are *denied* the session surfaces in v1).
- **Scoring**: no new scoring inputs. Valence remains non-scoring (ADR-10);
  divergence/tendency numbers are session-view derivations, never persisted
  back onto assessments.

## Deliberately deferred

| Deferred | Trigger to revisit |
|---|---|
| Participant follow-along devices + the narrow session-scoped visibility grant | Facilitator-only projection proves insufficient in real sessions |
| Auto-suggested contrast pairs in the compare tray | Manual pinning proves the gesture |
| **In-surface definitions for the calibration vocabulary** — see below | Before a session run by facilitators who didn't design the metrics |
| Cross-cycle calibration trend views ("is Raj converging?") | ≥2 cycles of session data exist |
| Automated bias scoring beyond the tendency strip | Never, ideally — the strip states facts; the room supplies judgment |
| Enforced session sequencing | No known need |
| Auto-resolving a clarification whose anchor entity is archived (it stays pending; the suggestion index / feed remain the manual resolve surfaces, and archived capabilities drop off the calibration surfaces anyway) | Stale open clarifications accumulate in practice |
| Assessee-facing disclosure of calibration visibility | With the v2 visibility grant (org-norm decision) |

### In-surface definitions for the calibration vocabulary

The session screens invent a vocabulary and then never define it. A
facilitator meeting *self-gap* or *spread* for the first time — on a
projector, mid-meeting, in front of their EMs — has nowhere to look, and a
metric nobody can define is a metric the room will quietly ignore or, worse,
misread as an accusation.

Every term below has a precise definition that already exists, in this doc
or in `OverviewStats`; none of it reaches the screen:

| Term | Where it appears | What it means |
|---|---|---|
| **Org mean** | tendency strip header | mean at-level manager rating across the whole population, 0–3 |
| **vs org mean** | tendency strip column | that rater's mean minus the org mean — their overall leniency/harshness |
| **Distribution** | tendency strip column | how that rater's at-level ratings split across the four frequencies |
| **Self-gap** | tendency strip column | mean of (manager − self) across the rater's cells: negative = they rate their people below those people's own view |
| **Evidence** | tendency strip column | share of that rater's at-level cells carrying ≥1 active evidence link |
| **spread** | divergence board row | max − min of rater means on that capability |
| **⚠ raters disagree** | divergence board badge | `divergence_score` (= min of spread and residual spread) reached `DIVERGENCE_FLAG_THRESHOLD` **and** the capability has enough rated cells (`FLAG_MIN_CELLS`) — i.e. disagreement that survives subtracting each rater's overall tendency, on a big enough sample (see *The unit of calibration*) |
| **solid vs outlined dot** | drill-in grid | evidence-backed vs unbacked, deliberately shape not colour |
| **Mgr:** stamp | evidence wall | the manager-rated frequency that cell carries in this cycle |
| **To confirm** | readiness badges | values exist but are carried forward from a prior cycle, unconfirmed this one |

Shape when picked up: a hover/focus definition on each term, reachable by
keyboard and not hover-only (the room is on a projector and the facilitator
may be driving by keyboard). Prefer one shared component over per-view
tooltips so the wording can't drift from the definitions above — and treat
these definitions as the source, since `OverviewStats`' comments and this
section already carry them.

### Carried-vs-vetted provenance on the read surfaces

Cross-cycle seeding (ADR-20) means a rating on screen can be last cycle's
decision, unexamined. The assessment side treats that as materially
different from "vetted this cycle" — it doesn't count toward completion and
renders **"To confirm"** — and the calibration surfaces now say so too.

**Marked, not excluded.** A carried value still counts toward every mean,
spread, distribution and denominator: it is real data, and dropping it would
silently move every number on screen. What each surface adds is *how much is
inherited*, so the room can discount rather than debate:

| Surface | Marker |
|---|---|
| Drill-in dot grid | a **dashed edge** — the shared "dashed means carried" primitive from `FrequencyPalette`; hue still means frequency and fill still means evidence backing, so the three signals never collide. A backed carried dot also drops to the lighter `chip_carried` tint (lighter = inherited). Legend gains "Carried from last cycle" |
| Person / compare cards | the Manager pill uses the palette's dashed-outline `pill_carried` variant plus "· carried" |
| Evidence wall | the same treatment on the `Mgr:` stamp — the room shouldn't norm against a grade nobody awarded this time |
| Tendency strip | a **Carried** column ("12 of 53", or "all N") |
| Divergence board | "· 1 of 2 carried" beside the spread, counted over **only the two raters whose means define that spread** — the comparison on screen. Counting the capability's whole cell set would both cry wolf (a carried cell belonging to a third rater who isn't in the comparison) and reassure wrongly ("2 of 20" when both extremes are wholly inherited). The row keeps its rank; the divergence is real in the data |

**Marking never softens (NON-NEGOTIABLE).** A carried rating is still the
rater's rating: declining to revisit it is a decision they own. So every
flag — the ▲/▼ tendency emphasis, the self-gap ⚠, the divergence badge —
fires on carried values exactly as on fresh ones, and the markers only say
*how the number got there*. The room's move is "own these, or do the work
to verify or amend them", which matters **most** when the carried numbers
show a real discrepancy, not least.

An earlier build suppressed the ▲/▼ emphasis on an all-carried row, on the
theory that a tendency nobody expressed this cycle isn't a coaching
conversation. That was wrong twice over: it let a rater escape their own
ratings by not touching them, and it went quiet exactly where the signal
was strongest. Don't reintroduce it. (The self-gap case is the sharpest
illustration: the reports' self-ratings are fresh, so a gap against a
carried manager value means they have formed a view this cycle that
disagrees with the record the manager is standing on.)

Known gap: the mirror case — fresh manager values against carried
*self*-ratings — is indistinguishable on these surfaces, because
`self_rating_source` isn't threaded into any calibration query yet.

Every marker is also stated in a `title`/aria string: per the palette's rule,
carried state must never rest on decoration alone.

Only `manager_rating_source == "seeded"` counts as carried — `nil` is a
legacy or factory row and is treated as human, matching
`Assessments::LevelCoverage`. Dev seeds emit ~15% genuinely carried ratings
so the markers are demo-able.

## Open questions

1. **Evidence author identity** — relation-first is the default and no
   per-item reveal is built. Should tenant config be able to name authors
   (some orgs are radically-transparent about feedback authorship)?
2. **Agenda persistence** — is the auto-agenda regenerated on every prep view
   until start (data may still be changing), then frozen with the session?
   (Proposed: yes — frozen agenda is part of the `SessionStarted` snapshot.)
3. **Revisit-request expiry** — do open revisit requests lapse at cycle close,
   or persist as unresolved on the follow-through page? (Proposed: persist,
   marked "cycle closed unresolved" — honest history beats tidy zeroes.)

## Keeping this document current

This is a design proposal. When implementation starts, move hardened
decisions into the appropriate guideline docs (a `calibration.md` guideline
once surfaces exist; aggregate specifics into an architecture doc alongside
the other aggregate docs), record ADR-worthy calls in
[adrs.md](adrs.md), and update or delete sections here that reality
supersedes rather than appending contradictions.
