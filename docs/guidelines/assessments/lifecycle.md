# Assessments — Lifecycle and Delegation

> Part of the [assessments.md](../assessments.md) guide set. Read this when: changing what a participation's status allows, alignment start / complete / re-open, carry-forward seeding, the status pill, or manager-rating delegation.

## Manager-rating delegation

When a report is **seconded into another team**, their reporting manager loses
direct visibility and can delegate the **manager rating** (but never alignment)
to someone closer to the work. Authority is enforced in Pundit AND, as a
defense-in-depth domain invariant, in the PersonDevelopment aggregate — see
[authorization.md](../authorization.md#assessment-permissions) and
[person-development-aggregate.md](../../architecture/person-development-aggregate.md).

- **Who is the manager** is recorded-authoritative: `RecordedReportingManager`
  (an event-sourced fact on the stream) is the source, with a live
  `Person.manager_id` fallback when nothing is recorded.
- **Delegate's experience** — the delegate sees the report in their index
  ("Team Assessments", unioned by active delegation) and opens the same
  `ManagerShowView`; they record manager ratings normally and see alignment
  read-only once it starts. They are treated like a manager for activity-feed
  visibility (`viewer_sees_all_evidence?` returns true for an active delegate)
  so they see the very ratings they record.

**Granting UI (manager view header).** The action cluster gains a **"Delegates ·
N"** button shown only when `@can_manage_delegates` (`delegate_manager_rating?` —
ancestor manager or tenant admin; the delegate never sees it). It opens a
`Kit::Modal` (standalone) whose body is the `delegations-list` Turbo Frame:

- A person `<select>` (candidates from
  `ManagerAssessmentDelegation.candidate_people`, excluding assessee / granter /
  current delegates) + optional `expires_at` + a submit.
- An active-delegate list, each with a ✕ revoke (`data-turbo-confirm`).

`Assessments::DelegationsController#create`/`#destroy` dispatch
`Operations::Assessments::{DelegateManagerRating,RevokeManagerRatingDelegation}`
(`approval :in_app`) and re-render the `delegations-list` frame so grant/revoke
update **in place** without closing the modal (200 on success; 404/422 on
failure — Turbo renders the frame either way). Expiry is **lazy** (filtered by
the `active` scope at read time); an expired grant can be **renewed** (the
aggregate's idempotency is expiry-aware).

**Activity feed.** Three framework-scoped entry kinds surface under "All" only
(no new filter chip — their `KIND_GROUP` is outside `CHIPS`):
`delegation_granted`, `delegation_revoked` (manager-rating privacy gate —
visible to manager + delegate, hidden from peers and from the assessee
pre-alignment), and `reporting_manager_recorded` (not sensitive → visible to any
viewer; only emitted on an actual manager change). A delegate's manager rating
renders a **"(delegate)" badge**, driven by `via_delegation` stamped on the
rating event at write time (accurate at event time — not reconstructed from
current state).

## Lifecycle

Each enrolled `AssessmentCycleParticipation` walks a lifecycle the views render explicitly:

```text
enrolled → started → aligning → aligned ─┐
                        ↑___________|    ├→ concluded  (cycle closes)
   (manager re-opens, cycle still open)  │
              any pre-close state ───────┴→ withdrawn  (person unenrolled)
```

| Status | Trigger | What's editable |
|---|---|---|
| `enrolled` | `PersonEnrolled` lands | Self + manager ratings (incl. delegate) |
| `started` | First `SelfRated` / `ManagerRated` with `source: "human"` — unless made through a lens on a cell the home role doesn't read | Self + manager ratings (incl. delegate) |
| `aligning` | Manager fires `AlignmentStarted` against the home role | Aligned values on the home role's cells — self + manager FROZEN there |
| `aligned` | Manager fires `FullAlignmentCompleted` against the home role | The home role's cells: nothing |
| `concluded` | Cycle closed (`AssessmentCycleConcluded` on the PD stream) | Nothing |
| `withdrawn` | Person unenrolled (`LeftAssessmentCycle` on the PD stream) | Nothing |

This is the **home** lifecycle — `AssessmentCycleProgress#status`, which the list, the cohort report and calibration read. Alignment against any other role runs beside it (ADR-22):

| Per role | Trigger | Effect |
|---|---|---|
| started | `AlignmentStarted{role_id, cell_keys, level_ordinal}` | A `AssessmentCycleRoleAlignment` row (`aligning`); the role's cells disclosed to the assessee and frozen for self + manager ratings |
| completed | `FullAlignmentCompleted{role_id}` | Row `aligned`; the agreed values on its cells are that conversation's record |
| re-opened | `AlignmentReopened{role_id}` | Row back to `aligning`, agreed values kept |

- **Freeze is per cell.** A self or manager rating is frozen once *any* started role reads its cell — the union — so starting PM3 freezes the cells E3 shares with it on the E3 page (the pill's title says "Frozen — alignment against PM3 has started") while E3-only cells stay editable. The aggregate enforces it (`ensure_individual_ratings_unfrozen!(cell)` over `cell_keys`), the rating Operations refuse with the reason first, and the builder marks each cell `frozen_by`.
- **An agreed value moves** while an alignment reading the cell is in progress, and never where a completed alignment already agreed it (`agreed_locked` per cell; `Disclosure#agreed_value_locked?` mirrors the aggregate).
- **Completion gates are per role**, over that role's cells at the conversation's level: PM3's cells never block E3 and vice versa.
- **History has no role.** Every `AlignmentStarted` before per-role alignment carries neither `role_id` nor `cell_keys`: it is the home role's and freezes the whole assessment, exactly as it always did — the aggregate replays it as `cells: :all`, and the projection's row carries `whole_assessment: true`, which `Disclosure` reads to freeze every cell.

**Concluded vs withdrawn (deliberate distinction).** A cycle closing is a
*conclusion*, not a removal: the participant stays part of the cycle's
historical cohort (cohort reports, participant counts, and manager cohort
access all keep concluded rows — the enrollment `active` scope is
`not withdrawn`). An unrated enrollment still concludes — "concluded" says
only that the cycle ended around them, never how far they got (that stays on
the progress row). `withdrawn` exclusively means a person-scoped removal
(opted out, left the company, enrolled by mistake). Historical PD streams
retain `LeftAssessmentCycle(reason: "cycle_closed")` from before the two
concepts were separated (immutable; the aggregate now rejects that reason for
new commands). The enrollment read model heals independently: a `CurrentState`
rebuild replays the historical **`CycleClosed`** events (its own stream's
input — PD events are not) and re-derives those close-withdrawn enrollment
rows as concluded.

**Re-opening a completed alignment.** A completion made by accident is
recoverable: the assessee's direct manager (never a delegate or the assessee)
can re-open while the cycle is still open via the "Re-open alignment" button,
which fires `AlignmentReopened`. The cycle returns to `aligning` — the agreed
per-cell values are **preserved** (no clearing) and the original
`alignment_started_at` stamps are kept; only the completion stamps
(`aligned_at` / `aligned_by_id` / `aligned_framework_version`) are cleared. The
manager resumes editing agreed values and re-completes via the normal "Mark
alignment complete" path (auto-align is a *start*-time behaviour and is **not**
re-run). Gated by `AssessmentPolicy#reopen_alignment?` (manager + open cycle +
status `aligned`). `AlignmentReopened` is a new event with no production
history, so the `CurrentAssessment` projection added a handler without a
`CODE_VERSION` bump or rebuild. Surfaces as an `alignment_reopened` activity
entry (alignment group, visible to both parties).

**Threading the status to the views.** `MatrixDataBuilder` produces two page flags for the role being read — from `participant_status` on the home role, from the lens role's alignment otherwise — and two per cell:

- `individual_ratings_frozen` — the role's alignment has started. Threaded through `CapabilityCardExpansion` as `frozen:`. In self/manager context, the primary `FrequencyPill` renders as a static (non-interactive) coloured span instead of an interactive trigger.
- `alignment_locked` — the role's alignment is complete. Threaded as `alignment_locked:`. In alignment context, the alignment selector also becomes a read-only bar.
- `cell[:frozen_by]` — the started alignment that froze the cell, any role's; the pill renders static with "Frozen — alignment against PM3 has started".
- `cell[:agreed_locked]` — the agreed value can't move here (see *Lifecycle*).

Both flags also flow through the rating controllers' Turbo Stream responses so post-event re-renders pick the correct read-only / interactive shape.

**Header layout.** Both `ShowView` and `ManagerShowView` render a single-row header (`flex flex-wrap items-baseline gap-x-3 gap-y-1`):

- **Self view** — H1 is the level title; shortcode chip is `"#{role.code}#{level.ordinal}"`; status pill (`In Progress` / `Ready for alignment` / `Aligning` / `Aligned`) when a cycle is open.
- **Manager view** — H1 is `assessee.name`; subtitle span renders the level title; same shortcode + status pill.

**Status pill** (`Views::Assessments::StatusPill`, wrapped in `id="assessment-status-pill"` for Turbo replacement; the two header layouts share it via `HeaderChrome#render_status_pill`). The pill rewards finishing the current-level ratings *before* the manager-driven alignment phase: while a cycle is open and the participant is pre-alignment, it reads **"In Progress"** (amber) until **current-level coverage hits 100% with vetted (human-owned) ratings** in the viewer's perspective — carried-forward values don't count until confirmed — then a green finished label that says whose move it is: **"Ready for alignment"** in the assessee's view (their part is done; the manager starts alignment next, which a `Kit::DefinitionTip` on the pill spells out on hover and keyboard focus) and **"Assessment Complete"** in the manager's. The same "Ready for alignment" shows on the Home page's "Your assessment" card, read from the projected `self_completed_at`, whose CTA then reads "Review self-assessment". "Complete" is `MatrixDataBuilder#current_level_complete?` — every capability with a cell at `person_level` rated under the context's primary frequency (self ratings for `:self`, manager for `:manager`); a role with no current-level cells is never complete. Because the pill lives in the static header (outside the scoring/matrix Turbo Frames), the self and manager rating controllers `turbo_stream.replace` it on every rating change so it flips live the moment the final cell is rated — no reload. `aligning`/`aligned` still win and show "Aligning"/"Aligned". Before either, when every current-level cell holds a value but some were carried, it reads **"N to confirm"** in the dashed carried chip rather than a bare "In Progress" (#480).

**Assessments list — dual-party status.** The `/assessments` list ([index_view.rb](../../../app/views/assessments/index_view.rb)) represents both parties. A **Team Assessments** (report) card shows a **Self** chip and a **Manager** chip, each `Not started` / `To confirm` / `In progress` / `Complete`; when both are complete it adds a quiet "Ready for alignment" cue. **Completion means VETTED THIS CYCLE**: carried-forward (seeded) values never count toward `Complete` — a side whose values are entirely carried reads **`To confirm`** (dashed amber chip, the carried signal shared with the pills and level chips), and any human touch (rate / revise / confirm / clear) tips it to `In progress`. The score/hero deliberately still count carried values (they're real data); the chips and pill track the *work state* — "here's the carried picture, your job this cycle is to vet it." A person's **own** card shows the **Self** chip only — the manager's progress stays private until alignment (privacy gate) — and the same "Ready for alignment" cue once their side is complete. The phrase means one thing everywhere: nothing on the viewer's side stands between this assessment and alignment. Once alignment starts, a single `Aligning` / `Aligned` chip replaces the per-side chips. "Complete" here is the **same current-level-coverage notion** as the header pill, so the Manager sub-badge and the report's "Assessment Complete" pill always agree.

**Skip-Level Assessments section.** Below Team Assessments, a manager-of-managers gets a **Skip-Level Assessments** section listing every assignment deeper in their org subtree. The Team/skip-level split has a single source of truth — [`Assessments::ReviewableAssignments`](../../../app/queries/assessments/reviewable_assignments.rb) (`team` = direct reports + active rating delegations; `skip_level` = subtree minus team) — consumed by both the web controller and the MCP `assessments_mine` operation (`direct_reports:` / `skip_level_reports:` keys), so the two surfaces cannot drift. Cards reuse the report-card layout (both-party chips + "Review assessment") and open the manager view **read-only** — the whole manager chain has view access (see *Context-Driven Rendering*), while rating stays with each person's own reporting manager. The section is **paginated with pagy** (`AssessmentsController::SKIP_LEVEL_PAGE_SIZE` per page, `?skip_page=` param, prev/next pager anchored to `#skip-level-assessments`) because a senior manager's subtree can hold hundreds of assignments.

The per-side `Complete` is a **projected, event-sourced fact**: [`CurrentAssessment`](../../../app/contexts/person_development/projections/current_assessment.rb) runs [`Assessments::LevelCoverage`](../../../app/queries/assessments/level_coverage.rb) on every rating change and stamps `assessment_cycle_progress.self_completed_at` / `manager_completed_at` (original completion time preserved across edits that stay complete; cleared when coverage drops). `status` stays the lifecycle phase — the two sides complete independently, so completion can't live in a single enum. The index reads those timestamps plus one cheap "any rating per side" query for the `Not started` vs `In progress` distinction (which needs no framework structure). `LevelCoverage`'s denominator mirrors `MatrixDataBuilder` exactly (active, role-bound capabilities with an expectation at the assessed level), pinned by a test. Known limitation: a `FrameworkVersionMigrated` that changes the current-level cell set without a subsequent rating can leave a stale flag until the next rating.

**Action cluster (right side).** Manager view with status `started` shows "Start alignment" (form with `data-turbo-confirm`); status `aligning` shows the gated "Mark alignment complete" control (below); status `aligned` shows "Re-open alignment". Status `aligning` or `aligned` automatically renders in alignment mode — no toggle. On a lens role the same two milestone controls act on that role's alignment (see *Per-role alignment*); its start lives in the lens banner.

**Completion gate (full current-level aligned coverage).** Marking alignment complete requires **every current-level capability to carry an agreed value**, so `aligned` status always means the formal record is whole — no cell scoring a silent 0.0 in the aligned perspective, and cross-cycle seeding never starts from gaps. Alignment is a shared act — either party can record agreed values — and the manager (who alone completes) can always record them, so the gate can never deadlock: it forbids leaving cells *implicit*, not disagreement (auto-align at start already clears explicit agreements; the residue is exactly the set that deserves the conversation). Enforced in **two layers**, both inside `Operations::Assessments::CompleteAlignment` (web and MCP): the aligned side of [`Assessments::LevelCoverage`](../../../app/queries/assessments/level_coverage.rb) over the role being completed gives the friendly count, then the counted cells go into `complete_alignment` as `required_cell_keys`, which the **aggregate re-checks atomically** against its replayed `@aligned_ratings` — serialized with any concurrent align/clear on the same stream, so a race can't slip a gap into the completed record. The split is deliberate: the denominator (which capabilities have a cell at the level) is framework structure the PersonDevelopment stream doesn't carry, so the edge supplies it and the aggregate enforces it. A cell a role gained after its alignment started (a framework publish mid-conversation) joins the role's cells when it is agreed against that role (`align_assessment(role_id:)`), so the gate never counts a cell nobody could agree. A role with zero current-level cells never blocks (mirrors the hero's zero-cell unlock). The UI mirror is `Views::Assessments::AlignmentCompletionControl` (`id="alignment-completion-control"`, desktop-only like the other milestone buttons): a disabled button + an amber "N to align →" jump chip (reusing the `continue-assessing` window-event bridge via the shared `ContinueAssessingLink`) while cells remain; the alignment-rating Turbo Stream responses replace it in place so it enables the moment the last cell is agreed. That live update is **actor-side only** — like the status pill and every other static-header element — so when the *assessee* records the final agreement, the manager's control catches up on their next interaction/reload (the acting-user convention; see framework-explorer.md Hard-Won Lesson 21).

**`AlignmentStartsController` / `AlignmentCompletionsController` / `AlignmentReopeningsController`** dispatch `Operations::Assessments::{StartAlignment,CompleteAlignment,ReopenAlignment}` (shared `Assessments::AlignmentMilestone` concern), each taking the lens's `as_role` / `as_level`, and redirect back to the page read through that lens. The Operations ask the per-role `AssessmentPolicy` predicates themselves — Pundit's `authorize` passes no role.

**Auto-alignment on start.** Inside the same RES transaction as `AlignmentStarted`, `PersonDevelopment::CommandHandler#start_alignment` emits an `AssessmentAligned` event for every (capability × level) cell **of the role being started, not already agreed,** where both `self_rated_frequency` and `manager_rated_frequency` are explicitly recorded **and equal**. The conversation in alignment mode then focuses on disagreements and unrated cells. Default-fallback agreements are NOT auto-aligned. Auto-aligned events carry the comment "Auto-aligned: self and manager already agreed".

**Cross-cycle seeding (carry-forward, ADR-20).** When a person enrols in a
new cycle, their ratings are pre-populated from their **most recent prior
participation** in the framework — aligned or not — with **per-cell
precedence**: a cell the parties agreed on carries the aligned value into
both sides (shared truth); a never-agreed cell carries each perspective's
own last value forward, so the alignment conversation resumes where it
stopped instead of starting blank. A side that never rated stays empty —
seeding records what existed, never fabricates agreement.
Most-recent-participation is lossless by construction: seeding chains, so
an unaligned cycle already contains the previous aligned baseline plus
whatever moved since. Seeded events carry `source: "seeded"` (vs the
default `"human"`) and `seeded_from_cycle_id`; idempotency is **per side**
(a human-touched side is never overwritten; the other side can still
seed). The participant stays in `enrolled` until their first real edit —
seeded events alone do not trigger `started`.

> This deliberately reverses the original aligned-cycle-only gate ("a
> partially-aligned cycle isn't a valid carry-forward baseline"): the
> alternative to an imperfect baseline is not a better baseline, it is
> blank — which punished a report for their manager's incomplete
> alignment (observed as inconsistent seeding across the Q3 2026 cohort).

**Carried-rating affordance.** A seeded rating the viewer hasn't confirmed
renders **distinctly from a fresh rating**, mirroring the below-level
assumed-consistent precedent (lighter = inherited, solid = explicit): the
`FrequencyPill` shows a dashed outline in the frequency's hue
(`pill_carried` in the palette), reads "Most of the time · confirm", and its
menu leads with **"Keep “Most of the time”"** under a note naming where the
value came from; a level chip whose
solid fill is entirely carried uses the lighter `chip_carried` tint (split
slices deliberately keep full tint — carried state there is visible on the
expansion pills). Non-visual parity via `title`/aria. Provenance is
**per side** on the read model (`self_rating_source` /
`manager_rating_source` — the row-level `source` flips to human on any
touch and can't say which side is still carried). **Interaction:**
selecting the shown value on a carried pill **confirms** it (re-emits as
human; the pill solidifies); untoggle-to-clear applies only to ratings the
person made themselves, and the popover's "Clear rating" posts an explicit
`rating[clear]` marker since the same-frequency POST is no longer
unambiguous.

**The confirmation work is named, not implied (#480).** A dashed outline was
the only signal, and people believed they had finished
([#480](https://github.com/mr-yum/growth-os/issues/480)). So:

- **Only cells that ask are marked.** `MatrixDataBuilder` reports a side as
  carried only at or above the scoring floor (`assumed_below`, the lower of
  the lens and home levels). Below it an unrated cell already reads as met
  and nothing counts it, so a carried value there wears no dashed treatment.
  Seeding still carries it: a lens at a lower level, or a later move to one,
  reads the value ([#481](https://github.com/mr-yum/growth-os/issues/481)
  explains why it isn't dropped).
- **Each surface says it.** The status pill reads **"N to confirm"** once
  every current-level cell holds a value (`current_level_work`); the hero
  swaps Continue for a "N to confirm →" jump chip at that point; a carried
  capability's name row wears **To confirm**. All three use
  `Components::Kit::ToConfirmChip`, and "still asks" is one predicate,
  `Concerns::RatedCount.to_confirm?` (carried on the viewer's side, not
  frozen).
- **A category confirms in bulk.** Its indicator cluster offers
  "Confirm N carried", a page (`Assessments::CarriedRatingsController`)
  listing every carried cell ticked, with its expectation and the feedback
  recorded this cycle beside it, so the confirm is informed. It posts to
  `Operations::Assessments::ConfirmCarriedRatings`, the same code as the
  `assessments_confirm_carried_ratings` tool. **That operation checks each
  cell is still carried before confirming it**: re-sending a value that is
  already human-owned through `RateSelf` *clears* it (the untoggle), so a
  stale list skips the cell rather than wiping it. Home role only; a lens
  confirms through its own pills.

**Bulk enrollment is a background job** (`AssessmentCycles::BulkEnrollmentJob`)
— each enrollment replays the person's PD stream and seeds carried ratings,
so a real cohort inline reliably times the request out. Per-person
transactions; skip-on-domain-failure; safe to re-run.
