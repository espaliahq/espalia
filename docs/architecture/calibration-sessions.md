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
> *Overview* — three tabs swapped inside a Turbo Frame (`?view=`, no
> scroll jump — the drill-in's pane pattern): rater-tendency strip,
> capability-divergence board, and **Score by cohort** (`OverviewStats` +
> `CohortScores`, both in `calibration_sessions_overview`); draft-phase
> agenda.
> *Drill-in* — expectation text with role illustrations, the rater × level
> dot grid, and a three-pane bottom half (person card / evidence wall §d /
> compare tray §e). The person card is a **read-only assessment column**:
> the capability's whole ladder as chips, a focused per-level panel
> (expectation + ratings + feedback/evidence), and the request-evidence /
> revisit asks in a kebab scoped to the focused level — see *The person
> card is a read-only assessment column*. See *Drill-in implementation
> notes* under §3.
> *Outcomes* — ⚑ expectation flags raising a framework **clarification**
> (the non-proposal suggestion kind, framework-explorer.md §12a); **revisit
> requests** mirrored onto the PD stream (`CalibrationRevisitSync`),
> surfaced in the rater's assessment feed and notified
> (`RatingRevisitNotifier`, dropped if already acted on), resolved by
> rating-change at read time; **evidence requests** (§f — the existing
> request machinery + session provenance, fulfilment read from the
> request); **session notes**.
> *Follow-through* — the session log, rendered as a right-hand activity
> side panel on both the session page and the drill-in.
> *Vocabulary* — every invented term (self-gap, spread, org mean, carried,
> the backing dot) defines itself in place, hover AND keyboard; see
> *In-surface definitions*.
> *Dev data* — `assessments:seed_calibration_activity` populates the current
> cycle, then advances the tenant through two more (`CalibrationHistorySeed`)
> so carried ratings, vetting-vs-coasting raters and reporting-line moves are
> real cross-cycle history, and leaves a live session to open. The org's
> high performers earn above-level surplus so ">100% of expected" and the
> drawer card's positive-only "Pulling it up" column are demo-able.
>
> *Provenance* — carried-forward (seeded, unconfirmed) ratings are marked
> on every read surface; see *Carried-vs-vetted provenance*.
>
> **Comparison drawer: SHIPPED** — the sticky bottom drawer (inspector +
> pins, side by side) shared by Score by cohort and the capability
> drill-in, replacing the inline why-panel, the bottom person card, and
> the separate compare tray; "What good looks like" folded into the
> column-header ⓘ menus + person cards; **⚑ Flag example as unclear**
> (illustration-anchored clarification,
> `Operations::CalibrationSessions::FlagIllustration`, web + MCP). The
> calibration screens use the full desktop width. See *The comparison
> drawer* below for the design record.
>
> **Not built** (each is marked at the section that describes it):
> auto-suggested contrast pairs (§e) · the person card's linked-by /
> requested provenance and
> valence↔rating coherence flag (§c) · prior-session markers on the grid
> (§3, *Overlapping sessions*) · participant follow-along + the v2
> visibility grant · cross-cycle trends · MCP reads for the drill-in
> surfaces (*Cross-cutting*).
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
| `CalibrationEvidenceRequestRaised` | live | provenance for a cell-scoped evidence request fired from the session (the request itself rides the existing machinery; fulfilment is read back from `EvidenceRequest`) |
| `NoteRecorded` | live | free-text minute, anchored to capability or person |
| `SessionClosed` | live→closed | facilitator action or cycle-close sync |

All writes dispatch through `Operations::*` classes (web + MCP parity, audit
metadata, the house rule).

### Read models

A session projection owning its own tables (session header, population
membership, agenda state). Per the read-model ownership invariant it never
writes to any other projection's tables; everything it displays about
ratings/evidence is a **read-time join** against `AssessmentLevelRating`,
`PersonFrameworkAssignment`, `RecordedReportingManager`,
`AssessmentCycleProgress`, and the evidence read models.

**Outcomes are NOT projected.** Flags, revisit requests, evidence
requests, and notes are read back off the session stream at render time
(`CalibrationSessions::SessionOutcomes`): a session's outcome count is
bounded by one meeting's discussion, so a table would carry a projection's
rebuild and ownership cost for a handful of rows. One `of_type` read per
render, shared across the surfaces that need it.

**The read is deliberately unbounded; the LOG's render is what is capped**
(`SessionLog::RENDER_LIMIT`). These events are not only a feed — the person
card suppresses an already-asked revisit from them and the flag operation
pre-checks an already-flagged cell — so an event dropped by a read cap
becomes an affordance the aggregate then refuses. If a session's log ever
outgrows the render cap, the fix is the framework feed's cursor "load older"
footer, not a read cap.

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
screen-shared display.

**The facilitator is NOT an ancestor of the entire population** — the original
design said subtree-scoped adds guarantee it, and that is wrong.
`ScopeChecks` deliberately exempts anyone a *participant* is attributed (an
active rating delegation, or a recorded reporting manager diverging from the
live chain), and those people sit outside the facilitator's subtree by
construction. So the session can contain someone `/assessments` would refuse
the facilitator, and `CalibrationSessions::AssesseeVisibility` checks the
entitlement per calibrant instead of assuming it. The line it draws:

- **The assessee's own contributions are gated** — feedback written about
  them, and their self-rating. Those are private inputs given under a
  disclosure naming their managers and admins, not a room of EMs. Outside the
  entitlement the wall and card omit the feedback, and the self pill reads
  "not shown" rather than a blank that would look like *unrated*.
- **Manager ratings are not gated.** They belong to a rater who is in the
  room to defend them; calibrating those raters is the session's purpose, and
  withholding them would empty the grid of exactly the cells the delegation
  exemption exists to include.

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
the session is a projected working surface, not a publication, and the
facilitator curated this population deliberately — a name is the least of
what they already know about someone they chose to put on the grid. (An
earlier draft justified this with "the facilitator is an ancestor of the
whole population"; that is not true — see *Access model* — but names are
not what the entitlement gate protects. What it gates is the assessee's own
contributions: their feedback and their self-rating.) If a room wants to debate the standard before
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

Every column is computed over the EM's **rated at-level cells** — the
population's cells at each person's own assessed level, with a manager
rating. "vs. org mean" compares against the mean of every such cell in the
session, all raters pooled (not the mean of the rater means, which would
weight a rater with two reports like one with nine).

```
            reports   vs. org mean      distribution     self-gap   evidence
  Mia          6        +0.4 ▲       ▁▂▅█  (skews high)    −0.1       21%
  Raj          5        −0.6 ▼       █▅▂▁  (skews low)     −0.8 ⚠     90%
  Sam          7        +0.1         ▂▅▅▂                  +0.1       55%
  Ana          5        −0.1         ▂▆▄▁                  −0.2       48%
```

- **self-gap** = mean(manager rating − self rating) over the EM's
  **at-level cells where BOTH sides rated** — a cell the report never
  self-rated has no gap to average, and counting it as zero would read as
  agreement. An independent bias signal (an EM far below their whole team's
  self-perception is either the room's only honest rater or has a calibration
  problem; either way, that's the conversation).
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

**Score by cohort** — the third tab: every calibrated person as an
initialed dot on a 0–200% axis (100 = meeting the level, 200 = the next level
in full — ADR-21), grouped by assessed level (the enrollment
snapshot) and coloured by WHO rated them, so "Raj's people cluster low"
is pre-attentive. Design rules, all deliberate:

- **The metric is the assessment's own number** — `% of expected`
  (`Scoring#performance_ratio`) at `perspective: :manager_only`, computed
  with the framework's own thresholds. The room and the individual's
  assessment can never disagree about arithmetic, % of expected stays
  comparable across roles sharing a level, and manager-only keeps the
  assessee's private self-ratings out entirely (no AssesseeVisibility
  interaction by construction).
- **The hero's coverage gate**: below half the at-level cells rated, no
  dot — an honest "4 of 12 rated · score unlocks at 6" chip instead of a
  misleadingly low number. Carried values COUNT toward coverage (they are
  real ratings; `LevelCoverage`'s seeded-exclusion measures *work-state*,
  a different question) and are disclosed per dot: a mostly-carried score
  wears the dashed ring.
- **Axis grammar is the divergence board's** — same track, same rater
  palette (`RaterColours`, shared), a labelled 100% reference line, a
  median tick per cohort (median over unlocked scores only). Near-tied
  dots drop to a second lane rather than overlapping.
- **Drill into why**: clicking a dot opens a server-rendered why-panel
  (`?cohort_person=`, swapped in the same frame) — the capabilities
  pulling the score down and up (`CohortScores#why_for`), each linking
  into the capability drill-in with that person's card open, composing
  with the existing surface. The **rater-context line** ("Mia rates +0.41
  vs org mean across their whole team") ties the tendency strip to this
  view — a low dot under a harsh rater is a calibration question, not a
  verdict.
- **Tabs live inside the frame** so the active chip can't drift from what
  the frame shows, and every off-page link inside the frame carries
  `data-turbo-frame="_top"` (the phlex-views.md in-frame trap — the board's
  capability links and the why-panel's drill-in links both hit it when the
  overview moved into a frame).

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
- **A silent rater collapses, everywhere in presentation — never in math.**
  Unrated cells never enter any aggregate (`OverviewStats#rated_cells`
  filters before anything is computed); the fix here is what RENDERS. A
  rater with nothing rated on the drill-in capability collapses to one
  muted sentence naming them and their people — the people as LINKS to
  their person cards, because the unrated cell is precisely the "what did
  you see?" moment and the card carries the evidence and the revisit ask
  (a full row of grey dots reads as data on a projector, but severing the
  card path would sever the outcome); the tendency strip keeps their row but
  says "No ratings yet" in place of zeroed columns; the divergence board
  names them in a footnote instead of a legend swatch that promises a dot
  existing on no axis. A PARTIALLY rated rater keeps a normal row — grey
  dots beside rated ones are the per-person gaps, which are data.
- **Rater dot palette order is load-bearing.** `RATER_DOT_CLASSES` cycles
  teal → purple → orange → pink → indigo → cyan. Orange sits third so pink
  never neighbours purple: the dark pair (pink-400/purple-400) is ΔE 13.3 —
  indistinguishable even to full colour vision — and the reorder lifts the
  worst adjacent pair to 27.8 (validated light AND dark). Initials on every
  dot remain the identity signal of record; don't reorder without
  re-validating both modes.
- **Prior calibration context — NOT BUILT** (overlapping sessions): a small
  marker on dots already discussed in an earlier session this cycle, with the
  outcome on hover — "discussed in Engineering calibration July 10 — revisit
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

> **Built:** the header (ratings, gap, carried marker, revisit ask) and the
> evidence list as *valence badge · author relation · date · excerpt*.
> **Not built** — the mock below is the target, not the current card:
> per-item linked-by and requested/proactive provenance; the
> valence↔rating coherence flag. The `[Request evidence…]` affordance IS
> built (§f). "Manager vs self" renders as two labelled rating pills, not the
> level chips' diagonal split — the split reads as *contested* between two
> parties looking at one chip, whereas the card has room to state both
> values outright.

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
 2 items · 1 proactive, 1 requested          [Request evidence…]  [Pin]
```

Card contents and rules:

- **Valence badge first** (`Views::Evidence::Valence` vocabulary — emerald /
  amber / rose, never the frequency palette: red/yellow/green/blue means
  *ratings*), then provenance, then the excerpt. Provenance today is author
  *relation* + date; linked-by and requested/proactive are not built.
- **Valence↔rating coherence flag (not built).** When the strongest linked
  valence contradicts the rating — *Strongly demonstrates* under a *Some*, or
  *significant growth area* under a *Consistently* — the card carries a quiet
  ⚠ "evidence and rating point in different directions". This is precisely a
  calibration conversation ("the evidence says more than the rating does —
  what else did you see?"), computed read-time from data that already exists.
  It is a discussion prompt, **not** a scoring input (ADR-10 stands: valence
  never feeds scoring).
- **Manager vs self** are stated as two labelled rating pills, each carrying
  its own carried-forward marker. (An earlier draft borrowed the level
  chips' diagonal split; the card has room for both values in words, and the
  split's meaning — *contested* — is the grid's job, not the card's.)
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

### f. Missing evidence as an outcome — BUILT

When a disputed cell is unbacked and the room can't answer "what did you
see?", the resolution *is* an evidence request. The person card's
**"Request feedback / evidence"** disclosure (a `<details>` beside the
revisit ask, not the assessment surface's modal — the card's outcome
affordances share one form vocabulary) offers the assessee's org
neighbours (`Assessments::RequestCandidates` — a pending ask on this cell
greys the person out) with one optional shared reason.
`Operations::CalibrationSessions::RequestEvidence`
(`calibration_sessions_request_evidence` over MCP) dispatches the SAME
PersonDevelopment command the assessment surface uses — hub card,
requestee notification, reminder sweep, response flow all ride along —
then records `CalibrationEvidenceRequestRaised` on the session stream.
Two streams, deliberately not atomic, request leads (the flag →
clarification shape).

**Two authorization bars, both in the Operation**: the facilitator bar
(outcomes are raised on the session's authority) AND the per-person
`EvidenceRequestPolicy#request?` — the delegation exemption means the
population can hold someone the facilitator has no assessment entitlement
for, and the session must not become a way to fire requests about them.
The card only offers the affordance inside the `AssesseeVisibility` set;
the Operation enforces it against a forged POST.

The log gains the fourth outcome kind (`evidence_requested`, emerald dot,
"Requests" chip); **fulfilment is read from the `EvidenceRequest` read
model at render time** ("Awaiting response" / "Answered" / "Declined") —
resolution state is never duplicated onto the session stream, matching
rating-change-based revisit resolution.

### Data notes

Everything above is read-time over existing read models (`EvidenceItem`,
`EvidenceLink` + valences, per-cell like the assessment screen reads them).
The only evidence-related *write* from a session is (f) — the existing
PersonDevelopment command plus a session-stream provenance event. No new
evidence tables, no projection changes.

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
3. **Request evidence** for an unbacked disputed cell (see evidence §f —
   built; provenance on the session stream, fulfilment read from the
   request itself).
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
  re-litigate. **Not built** — the semantics below hold today (sessions
  already run concurrently with no coordination); the surfacing does not.
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
  `calibration_sessions_overview` also carries `cohorts` — per-person % of
  expected with the coverage gate verbatim (`pct` nil + `rated`/`total`/
  `unlock_target` when gated): an agent must never read a gated person as
  low-scoring.
  *Payload gotcha:* `calibration_sessions_overview` returns `cell_count`
  under two different denominators. On a **rater** row it is that rater's
  whole rated at-level cell set; on a **capability** row it covers only the
  raters sitting at the two means that define the spread — the comparison
  the board displays. `carried_count` follows its row's denominator. Read
  them per row, never across the two.
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
| Cross-cycle calibration trend views ("is Raj converging?") | ≥2 cycles of session data exist |
| Automated bias scoring beyond the tendency strip | Never, ideally — the strip states facts; the room supplies judgment |
| Enforced session sequencing | No known need |
| Auto-resolving a clarification whose anchor entity is archived (it stays pending; the suggestion index / feed remain the manual resolve surfaces, and archived capabilities drop off the calibration surfaces anyway) | Stale open clarifications accumulate in practice |
| Assessee-facing disclosure of calibration visibility | With the v2 visibility grant (org-norm decision) |
| Extracting the drawer card SHELL (container/header/✕/Pin) shared by the cohort and capability faces — today duplicated between `CohortDrawerCard` and the drill-in's `drawer_card` | The next change that touches the 38vh cap, pinned ring, or dismiss controls in both places |
| Batching the drill-in drawer's per-card queries (`PersonCard` ladder/ratings/evidence run per person; a full drawer is ~4×, bounded by the 3-pin cap) | The cap rises, or drawer renders show up in traces |

### In-surface definitions for the calibration vocabulary — BUILT

The session screens invented a vocabulary and never defined it. A
facilitator meeting *self-gap* or *spread* for the first time — on a
projector, mid-meeting, in front of their EMs — had nowhere to look, and a
metric nobody can define is a metric the room will quietly ignore or, worse,
misread as an accusation.

Every term below now carries its definition on the surface that renders it:

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

Shape as built:

- **`Views::CalibrationSessions::Glossary`** holds the wording — one `TERMS`
  hash, mixed into every calibration view via `defined_term(:self_gap)`, so
  the strip, the board, the drill-in legend and the readiness badges cannot
  drift apart. If a definition here and `OverviewStats` ever disagree, the
  code is right and the room has been misled — fix the wording.
- **`Components::Kit::DefinitionTip`** is the mechanism: a real `<button>`
  wired to its panel with `aria-describedby`, revealed on hover **and** on
  focus. Deliberately not the native `title` attribute, which no keyboard
  user can reach — and the facilitator is often driving by keyboard with the
  room watching a projection. Pinned by a system-test assertion that focuses
  the term and expects the panel (`send_keys` with no click).
- **The panel rides the top layer** (`popover` + `definition_tip_controller`),
  because the tendency table scrolls horizontally and an `overflow-x: auto`
  ancestor clips on BOTH axes — the spec gives no way to keep one axis
  visible, so the CSS-only version had half of every definition sliced off at
  the card's edge. The CSS hover/focus classes remain as the no-JS fallback.
  The same system test measures the panel's rect against the viewport, since
  this is invisible to any DOM-only assertion.
- **The info glyph is drawn, not typed.** U+24D8 (ⓘ) rendered as a tofu box
  in the headless browser's font — on a surface whose whole job is legibility
  on a projector — so it is an inline SVG.
- **A term with an adjacent value is one trigger** ("spread 1.3", "Org mean
  1.82") rather than a term, a glyph, and then a number — the whole stat is
  what the reader points at, and a glyph mid-phrase breaks it.
- **A term that already has a visual form keeps it**: "⚠ raters disagree"
  stays an amber badge and "To confirm" stays the dashed carried chip, via
  `trigger_class:`. The tap target and focus ring are added either way.

### Dev data — a history, not a snapshot

`assessments:seed_calibration_activity` populates the open cycle, then hands
off to `CalibrationHistorySeed` (`lib/tasks/`, outside Zeitwerk's eager-load
so it can't reach production).

The point of the second half: **carried ratings are a claim about a previous
cycle, so they need one.** The single-cycle seed could only fake them by
writing `source: "seeded"` directly. Now each cycle is closed and the next
enrolled through `BulkEnrollmentJob` — the same path production uses — so
ADR-20's cross-cycle seeding does the carrying, with the real events and
provenance. What that buys the surfaces:

- **Raters who vet and raters who coast**, assigned by RANK over each
  cycle's raters rather than an independent draw per rater — ranking
  guarantees all three states appear, where independent draws can leave a
  small tenant entirely coasting, which is precisely the demo the Carried
  column cannot make.
- **Reporting-line moves** between cycles, always to a sibling under the
  same department head (the re-org that actually happens, and one that keeps
  everyone inside the facilitator's scope). Applied to the org chart AND
  recorded on the PersonDevelopment stream, so the drill-in attributes by
  the recorded fact.
- **A live session on the current cycle**, because otherwise every visual
  check of this feature begins by hand-rolling one that satisfies the
  population rules.
- **Above-level surplus for the org's high performers** (top ~30% by base
  competence, consistent-ish at L+1 on ~60% of behaviours). Without it no
  seeded person can read "above expectations" — every rating sits at the
  enrolled level, performance never exceeds 100%, and the cohort
  why-panel's positive-only "Pulling it up" column is empty by
  construction. Skipped under a coasting rater (a fresh human rating would
  break their "all carried" story).

Re-running converges rather than growing: cycles are keyed by name, the
session by cycle, and every persona derives from a SHA of stable ids.

### The comparison drawer

Both comparison surfaces exist to calibrate how each individual is
presented, so they share ONE presentation of a person. **The rule:
clicking any person anywhere in the module opens them in the inspector —
the left slot of a sticky bottom drawer; pinning holds them side by side
while the next person opens.** Comparison is a horizontal act — two
ladders compare by eye, not by memory — and the bottom placement keeps
the session log visible throughout. Design decisions:

- **Three panes everywhere**: main pane · session log (far right,
  unchanged) · the comparison drawer pinned to the bottom of the
  viewport. The drawer renders only when the inspector or ≥1 pin is
  occupied. The drawer has NO header row — being the comparison is
  self-evident, so every vertical pixel goes to the cards; the controls
  float on the top edge: a drag handle (resize; persists via cookie;
  dragging within 20px of the viewport bottom collapses) and a ✕ that
  collapses to a slim expand bar carrying the pin count. Pins keep
  their positions and the just-opened person APPENDS; each card has ONE
  dismiss (✕ — unpins a pinned card, closes an unpinned inspector) plus
  Pin to hold. Anyone held in the
  drawer — inspected or pinned — reads by SIZE on the grid / cohort dots
  (1.5×, no ring or corner disc), so "already held below" is
  pre-attentive in the main pane. The host
  page is padded by the drawer's measured height, so page-end content
  always scrolls clear. Mobile is the SAME drawer one card wide.
- **Inspector + pins, max 3 people across** (the compare tray's cap;
  horizontally scrollable if cramped). A pin is a PERSON, not a
  snapshot: the card renders the context's face — cohort face (% of
  expected, gate, why columns, rater-tendency note) on the session page;
  capability face (the read-only ladder + level panel) on the drill-in.
  Pins ride every calibration-internal link, so they survive tab
  switches, capability changes, and the cohort → drill-in jump. This
  retires the inline why-panel, the bottom person card placement, and
  the separate `?view=compare` tray — one component, three fewer
  surfaces.
- **Sticky main-pane headers — must-have context only**: the overview
  tab bar (session page); one compact line of category · capability plus
  the grid's rater/level header row (drill-in). Back link, log toggle,
  and expectation text scroll with the flow — chrome, not context.
- **"What good looks like" folds in** (drill-in): the standalone card is
  replaced by (a) the sticky focused-level expectation line, (b) an ⓘ on
  each level column header — a dialog panel with the expectation, the
  role examples (each flaggable), and "⚑ Flag expectation as unclear…"
  (the no-person-open path), and
  (c) the person card's level panel, which gains the Examples disclosure.
- **One kebab**: the person card's ⋮ carries Request feedback/evidence…,
  Ask the rater to revisit…, and (drill-in) ⚑ Flag expectation as
  unclear… — all scoped to the focused level.
- **Flag example as unclear** (new): a clarification anchored on the
  role illustration — same table, lifecycle (required note to resolve),
  feed rails, and light review tier as expectation flags; a new anchor
  type only.
- **State stays URL-carried**: `person=` (inspector) + `person_level=` +
  `pins[]=`, stamped by the existing pane-state machinery; `compare[]`
  and `cohort_person` retire into them.

All three phases are shipped: the drawer on both screens (person= +
pins[] URL-carried, `compare[]`/`cohort_person` retired), the sticky
capability header + in-card grid scroll with pinned level headers, the
"What good looks like" fold-in (column-header ⓘ menus with expectation +
examples + flags; examples and the focused expectation on every person
card), and per-example flags (`CalibrationExpectationFlagged` carries an
optional `illustration_id`, so the cell's flag and each example's flag
are independent one-per-session outcomes).

### The person card is a read-only assessment column

A person can be rated **above their level**, so the drill-in's person card
renders the capability's whole ladder, not just the assessed cell — a
read-only adaptation of the assessment capability view:

- **Level strip** — one chip per rung of the role ladder (ADR-19 enrollment
  snapshot; a pre-snapshot enrollment degrades to the assessed level alone),
  in the assessment chip vocabulary at manager perspective: solid palette
  fill when rated, the lighter carried tint + dashed edge when inherited,
  assumed-consistent blue below the assessed level, neutral above. The
  assessed level wears **CURRENT**; chips are pane links
  (`?person_level=`) so switching levels swaps the card in place.
- **Focused panel** — initial focus is the assessed level; it shows that
  cell's expectation text, Manager + Self pills (self withheld under
  AssesseeVisibility, as before), the revisit marker when this session
  already asked about that cell, and the feedback / evidence linked at
  that level.
- **Kebab actions** — "Request feedback / evidence…" and "Ask the rater to
  revisit…" live in one ⋮ menu on the card header (the assessment-surface
  pattern). Each item is a `?person_action=` pane link that opens the form
  scoped to the FOCUSED level — the ask is about the cell on screen, which
  may sit above the assessed level. Gates unchanged (live session, viewer
  entitlement, one revisit ask per cell per session).
- The cohort why-panel's "Open drill-in →" anchors at
  `#calibration-person-card`, landing the reader on the card it names.

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
| Divergence board | "· 1 of 2 carried" beside the spread, counted over **only the raters sitting at the two means that define that spread** — the comparison on screen (every rater at an extreme, so a tie counts them all). Counting the capability's whole cell set would both cry wolf (a carried cell belonging to a rater in the middle, who isn't in the comparison) and reassure wrongly ("2 of 20" when both extremes are wholly inherited). The row keeps its rank; the divergence is real in the data |

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
