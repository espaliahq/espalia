# Person Development Aggregate

> Read this when: working on assessments, evidence, growth plans, alignment conversations, check-ins, framework migration for in-progress assessments; writing person development events, commands, or projections.

One RES stream per person per framework: `tenant-{tenant_id}/PersonDev-{person_id}-{framework_id}`

---

## Events

```
Assignment:
  PersonAssignedToFramework { framework_id, role_id, level_id, assigned_by? }
  PersonRoleChanged { previous_role_id, new_role_id, previous_level_id, new_level_id, reason, changed_by? }
  PersonLevelChanged { previous_level_id, new_level_id, reason, changed_by? }
  PersonUnassignedFromFramework { previous_role_id?, previous_level_id?, reason, unassigned_by? }
    ← assigned_by / changed_by / unassigned_by are nil for system-driven HRIS syncs
      (provenance is then the metadata layer: acting_via: :hris + correlation_id). See ADR-18.
    ← migrate_framework_version RAISES if the current cycle's alignment is
      completed — a completed assessment is immutable (ADR-19).
    ← unassign_from_framework is the EXIT from the assign → change_role → change_level
      lifecycle: it removes the assignment entirely (used when the real role no longer
      maps to a framework role, or to correct an erroneous assignment). Guards:
      ensure_assigned! AND refuses while @current_cycle_id is set — unenroll first
      (cycle membership is manager-driven) so no in-flight rating/evidence is orphaned.
      Clears @assigned, so the person can be re-assigned afterward. The CurrentAssessment
      projection deletes the PersonFrameworkAssignment row; the event is the audit trail.
      MUST stay an explicit action — never auto-fired by HRIS on an unmapped title
      (unmapped titles are skipped + tracked, deliberately non-destructive).

Evidence (one piece of evidence can be linked to MANY capability × level
cells — multi-linkage. Content lives on EvidenceRecorded/Updated; the set of
links is maintained by EvidenceLinkAdded/Removed):
  EvidenceRecorded { id, capability_stable_id?, level_ordinal?, source, evidence_type,
                     custom_type_label?, title?, content, external_reference?, author_id,
                     valence? }
    ← Creates the item AND its FIRST link. The capability_stable_id/level_ordinal
      here are the item's ORIGIN link (also the read-model EvidenceItem columns
      the activity feed anchors on).
    ← UNPLACED: capability_stable_id, level_ordinal and valence all nil — feedback
      volunteered without a capability in mind. No link until add_evidence_link
      places it (anyone EvidencePolicy#add_link? admits). A cell is both halves
      or neither; a valence or additional_links without a cell are refused.
      Every event published before unplaced feedback carries a cell.
    source: self | manager | peer
    ← An author recording evidence about themselves must use source self; the
      aggregate refuses any other. Answers to a request about one's own
      assessment were recorded as peer until October 2026, so readers that
      bucket by source also check EvidenceItem#self_authored?.
    evidence_type: peer_feedback | project_outcome | code_review | design_review |
                   customer_feedback | incident_response | presentation | mentoring | other
    external_reference: { system, url?, external_id?, metadata? }
  EvidenceLinkAdded { evidence_id, capability_stable_id, level_ordinal,
                      linked_by_id, rationale? }
    ← Attaches the item to an additional cell; it then surfaces there too.
  EvidenceLinkRemoved { evidence_id, capability_stable_id, level_ordinal,
                        removed_by_id, reason? }
    ← Detaches one link. DOMAIN INVARIANT: a PLACED active item must always keep
      ≥1 link — removing the last link is rejected (withdraw the item instead).
      An unplaced item has no link to remove; its first link puts it under the rule.
  EvidenceRelinked { evidence_id, previous_capability_stable_id, previous_level_ordinal,
                     new_capability_stable_id, new_level_ordinal, relinked_by_id, rationale? }
    ← HISTORICAL ONLY — no longer emitted (the user-facing "move" action was
      replaced by add-link + remove-link). Retained so replay reconstructs the
      link set correctly (treated as remove previous + add new).
  EvidenceUpdated { evidence_id, title?, content, evidence_type,
                    custom_type_label?, external_reference?, edited_by_id }
    ← Carries the FULL post-edit value of every mutable field (snapshot, not a
      delta). Mutable scope is strictly the user-correctable content: title,
      content, evidence_type, custom_type_label, external_reference. The
      capability/level links are owned by the link events; source,
      author_id, and recorded_at are identity invariants and never change.
      Authorization is strictly author-only — no admin override — see
      EvidencePolicy#update?.
  EvidenceWithdrawn { evidence_id, reason, withdrawn_by }
    ← Withdraws the item everywhere (all its links at once).

  Link management (add_link / remove_link) authorization mirrors the retired
  relink: author + assessee + manager chain + an active manager-rating
  DELEGATE — see EvidencePolicy#add_link?/#remove_link?.

Assessment cycle:
  AssessmentCycleOpened { cycle_id, cycle_name, cycle_type, framework_version_id }
    cycle_type: regular | performance_review | promotion_review
  AssessmentCycleCompleted { cycle_id }

Evidence and feedback:
  EvidenceRecorded { evidence_id, capability_stable_id?, level_ordinal?, source,
                     evidence_type, custom_type_label?, title?, content,
                     external_reference?, author_id, cycle_id?, valence?, request_id?,
                     recorded_at? }
    ← The cell and its valence are nil together for an UNPLACED item (see above).
    ← recorded_at (UTC ISO 8601) is when the feedback was GIVEN, carried only when
      that is earlier than the event: an item imported from a peer system
      (FeedbackExchange::Importer, `acting_via: feedback_exchange`) is dated by the
      peer's `given_at`, so a backfill reports in the month it was given. The
      EvidenceCollection projection reads it and falls back to the event's own
      timestamp, which is what every other event and every historical event uses;
      the field is additive and needed no CODE_VERSION bump.
    ← request_id names the request this item answers (record_evidence_for_request
      publishes it with EvidenceRequestResponded in one unit of work). A reader of
      this event alone — the feedback notifier — can tell a response from
      volunteered feedback without the request's own event having been projected.
    ← cycle_id is assigned when the feedback is first provided and is immutable.
      Relinking an existing item in a later cycle does not change its attribution
      or count it as newly provided feedback. Evidence recorded outside a cycle,
      and historical events published before attribution existed, may have no ID.
  EvidenceRequested { request_id, requested_by_id, requestee_person_id,
                      capability_stable_id, level_ordinal, cycle_id?, message?, due_at? }
    ← cycle_id is assigned when the request is sent. A response keeps the request's
      cycle even when it arrives after the participant leaves or the cycle closes.
  EvidenceRequestResponded { request_id, evidence_id, responded_by_id }
  EvidenceRequestDeclined { request_id, declined_by_id, reason? }
  EvidenceRequestCancelled { request_id, cancelled_by_id }
  EvidenceRequestReminderSent { request_id, kind, nudged_by_id? }
    kind: no_response | due_soon | manual
  EvidenceLinkAdded { evidence_id, capability_stable_id, level_ordinal, valence,
                      linked_by_id, via_suggestion_id? }
  EvidenceLinkRemoved { evidence_id, capability_stable_id, level_ordinal, removed_by_id }
  EvidenceLinkRevalenced { evidence_id, capability_stable_id, level_ordinal,
                           valence, changed_by_id, via_suggestion_id? }
    ← via_suggestion_id: the EvidencePlacementSuggestion the person accepted
      (ADR-18 payload attribution). Present only when the link decision came
      from a suggestion; absent on every other event, historical or not, so
      consumers tolerate nil and no projection needed a CODE_VERSION bump.
      The suggestion itself is plain state, not an event: machine output,
      regenerable, worthless once decided (assessments/evidence.md →
      Suggested placement and valence).
  EvidenceUpdated { evidence_id, title?, content, evidence_type, custom_type_label?,
                    external_reference?, edited_by_id }
  EvidenceWithdrawn { evidence_id, reason, withdrawn_by_id }

Self-assessment:
  SelfRated { capability_stable_id, level_ordinal, frequency, comment, source, seeded_from_cycle_id }
    frequency: "none" (0×) | "some" (⅓×) | "occasional" (⅔×) | "consistent" (1.0×)
    source: "human" (default, person entered it) | "seeded" (carried from prior cycle's
            aligned value at cycle join) | "agent" (reserved for future AI-generated ratings)
    seeded_from_cycle_id: UUID of the originating cycle when source == "seeded".
  SelfRatingRevised { capability_stable_id, level_ordinal, frequency, comment, rationale }
    ← Always flips the row's source back to "human" — any user revise is a real edit.
  SelfRatingCleared { capability_stable_id, level_ordinal }
    → Removes a self-rating (untoggle). Projection nils the frequency on the read model.
      Scoring falls back to the default for that cell.

Manager assessment:
  ManagerRated { capability_stable_id, level_ordinal, frequency, comment, source,
                 seeded_from_cycle_id, rated_by_id?, via_delegation? }
    Same source / seeded_from_cycle_id semantics as SelfRated.
    ← rated_by_id: the manager who rated (a domain fact — the assessee's manager
      changes over time). nil for "seeded" carry-forwards and historical events.
      Projected to AssessmentLevelRating.manager_rated_by_id. See ADR-18.
    ← via_delegation: true when recorded by an active delegate rather than the
      recorded reporting manager. Stamped at write time by the aggregate (which
      knows @manager_id + @active_delegates) so the activity feed badges it
      accurately at event time. Absent on historical events. See "Reporting line
      & delegation" below.
  ManagerRatingRevised { capability_stable_id, level_ordinal, frequency, comment, rationale, rated_by_id?, via_delegation? }
    ← Like SelfRatingRevised, always flips the row's source back to "human".
  ManagerRatingCleared { capability_stable_id, level_ordinal, cycle_id, rated_by_id?, via_delegation? }

Reporting line & delegation:
  ReportingManagerRecorded { manager_id, previous_manager_id?, source }
    ← Makes "who is the person's reporting manager" a first-class, immutable
      fact ON the stream (per person × framework), rather than reading the
      mutable Person.manager_id at check time. source: "hris" | "backfill".
    ← Idempotent: the aggregate no-ops when the manager is unchanged, so only an
      actual change emits an event (low-volume, genuine history). Populated by
      the HRIS sync (every touched person with an assignment) and a one-off
      backfill (events:backfill_reporting_managers).
    ← AUTHORITY SOURCE OF TRUTH. Both the aggregate's manager-rating invariant
      (below) and AssessmentPolicy#manages_assessee? read the RECORDED value and
      fall back to live Person.manager_id only when nothing is recorded yet
      (manual / non-HRIS tenant, or pre-backfill).
  ManagerRatingDelegated { delegate_person_id, granted_by_id, expires_at?, reason? }
    ← Grants manager-RATING authority (not alignment) for one report on one
      framework to another person — e.g. a report seconded into another team.
      Does not require an open cycle; persists across cycles until revoked/lapsed.
      Idempotent against a still-active grant; an expired grant can be renewed.
  ManagerRatingDelegationRevoked { delegate_person_id, revoked_by_id }
    ← Non-destructive: ratings the delegate already made remain (attributed to
      them via rated_by_id); only future rating is stopped.

  Manager-rating invariant (ensure_manager_authority!): a ManagerRated /
  ManagerRatingRevised / ManagerRatingCleared must be attributable to the
  recorded reporting manager (@manager_id) or a non-expired delegate
  (@active_delegates, an id → expires_at map). Fail-open when the source is
  non-"human" (seeded/system) or no manager is recorded. Two-stage rollout:
  Stage 1 (current) LOGS divergence; Stage 2 will RAISE after the prod backfill
  and clean divergence logs. Granter authority (ancestor manager or tenant
  admin) is NOT checked here — that stays in Pundit, since the aggregate only
  knows the direct recorded manager.

Alignment lifecycle (per cycle, per role — ADR-22):
  AlignmentStarted { cycle_id, started_by_id, role_id?, level_ordinal?, cell_keys? }
    ← Manager-only. Alignment is against a role: the home role (the role
      held at the join, moved by a transfer until any alignment starts in the
      cycle, then pinned) or a lens role. The aggregate
      holds @alignments[role_id] = { completed:, cells: Set | :all } and
      FREEZES self/manager ratings on the UNION of every started role's cells
      (ensure_individual_ratings_unfrozen!(cell)) until leave/conclude.
    ← cell_keys: the role's [capability_stable_id, level_ordinal] cells at
      start. The stream carries no framework bindings, so the command handler
      reads them from Assessments::RoleScope — the same shape as
      required_cell_keys on complete_alignment.
    ← HISTORY: every event before per-role alignment has no role_id and no
      cell_keys. It is the home role's and its cells are :all — the whole
      assessment froze, and replay reproduces that exactly. A start with
      cell_keys: nil still means :all (only reachable by calling the
      aggregate directly; the handler always supplies them).
    ← A second start against the same role raises; another role can start.
      A home start flips participant status to `aligning`; a lens start
      leaves the home lifecycle alone.
    ← The aggregate additionally emits an AssessmentAligned event for every
      cell OF THE ROLE, not already agreed, where both self_rated_frequency
      and manager_rated_frequency are explicitly recorded, human and equal —
      all inside the same with_person_development block. Default-fallback
      and seeded matches do NOT auto-align.
  AssessmentAligned { capability_stable_id, level_ordinal, aligned_frequency, cycle_id, comment, aligned_by_id?, role_id? }
    ← Per-cell agreed frequency. Requires an alignment IN PROGRESS whose
      cells include the cell, and refuses to rewrite a value a COMPLETED
      alignment's cells include. Agreed level is DERIVED (never stored):
      max(level_ordinal where aligned_frequency == "consistent").
    ← role_id: the role the pair aligned against, when the caller checked
      that role reads the cell. A cell the role gained after its start (a
      mid-conversation framework publish) joins the role's cells here, so
      the completion gate never counts a cell nobody could agree. Absent on
      history.
    ← aligned_by_id: who recorded the agreement (manual = the submitter; the
      cells auto-aligned at start = the manager who started). Projected to
      AssessmentLevelRating.aligned_by_id. See ADR-18.
  AlignmentCleared { capability_stable_id, level_ordinal, cycle_id, cleared_by_id? }
    ← Same per-cell rule as AssessmentAligned.
  FullAlignmentCompleted { cycle_id, completed_by_id, framework_version?, role_id? }
    ← Manager-only, per role. The role's agreed values become that
      conversation's record. For the home role: flips participant status to
      `aligned`. SNAPSHOT POINT — long streams will compress here when
      snapshotting infrastructure ships. required_cell_keys gate the role's
      own current-level cells (atomic re-check).
    ← framework_version: the version this cycle was assessed against at
      completion (join version, advanced by any mid-cycle migration). Projected
      to AssessmentCycleProgress.aligned_framework_version for reporting. A
      completed assessment is immutable as-at-completion — see ADR-19.
    ← role_id nil on history = the home role.
  AlignmentReopened { cycle_id, reopened_by_id, role_id? }
    ← Per role; agreed values kept. role_id nil on history = the home role.

  Read models (CurrentAssessment): AssessmentCycleProgress keeps the HOME
  lifecycle; AssessmentCycleRoleAlignment holds one row per role started
  (home included; `whole_assessment` marks a start from history).
  AssessmentCycleProgress tracks the home (`home_role_id`, `home_level_id`)
  from the projection's own events, as the aggregate does: set at the join,
  moved by a transfer or promotion until any alignment starts. A role-less
  event from history is that home's. The projection never reads the
  enrollment snapshot, which a rebuild would see as it ended, not as it
  stood at the event (#687). `PersonFrameworkAssignment.current_cycle_id`
  names the cycle a role change lands in.

Declared explorations (ADR-22 — intent, not a rating scope):
  ExplorationStarted { exploration_id, target_role_id, target_level_id, target_level_ordinal,
                       started_by_id, note? }
    ← "We've agreed to explore PM3." Declared by the assessee, their recorded
      reporting manager or an active rating delegate (Pundit, not the
      aggregate). Needs an assignment, NOT an open cycle — it rates nothing,
      so the open-cycle rule for writes (D7) doesn't apply — and survives
      join / leave / conclude: @explorations is never reset by a cycle.
    ← One open exploration per target role; refuses the role AND level the
      person holds (the live assignment on the stream; the Operation also
      refuses the enrollment-snapshot home). The next level of the same role
      is allowed — a vertical exploration.
    ← exploration_id is caller-minted and is the read model's primary key.
  ExplorationClosed { exploration_id, closed_by_id, outcome, note? }
    ← outcome ∈ pursue | not_now | moved. Only an open exploration closes;
      whoever may declare may close, whoever declared it.
    ← Also emitted by change_role / change_level, right after the change,
      for every open exploration whose target role AND level the person now
      holds: outcome "moved", closed_by_id = the change's changed_by (nil for
      an HRIS sync).

  Read model (CurrentAssessment): AssessmentExploration, one row per
  exploration. Never read by a cohort surface.

Cross-cycle seeding:
  RatingSeedSkipped { capability_stable_id, level_ordinal, prior_aligned_frequency,
                      current_cycle_id, prior_cycle_id, reason }
    ← Audit-only. Emitted during seed-from-prior-cycle when a prior aligned
      capability's stable_id no longer exists in the new cycle's framework
      version. No projection writes a read model row today; the future
      framework-migration UI will replay these to surface a "use this rating"
      affordance against the migrated equivalent capability.

Growth plan:
  GrowthGoalSet { goal, goal_type, target_date, set_by }
    goal_type: close_gaps | next_level | career_mobility | skill_development
  GrowthGoalRevised { new_goal, new_goal_type?, new_target_date?, rationale, revised_by }
  FocusAreaAdded { id, title, capability_stable_id?, gap_identified,
                   success_criteria, action_plan, action_type?, added_by }
    action_type: on_the_job_70 | coaching_20 | training_10
  FocusAreaUpdated { focus_area_id, field, new_value, rationale, updated_by }
  FocusAreaStatusChanged { focus_area_id, old_status, new_status, evidence?, changed_by }
    status: not_started | in_progress | achieved | deferred
  FocusAreaRemoved { focus_area_id, reason, removed_by }
  FocusAreaReprioritised { new_ordering, reprioritised_by }
  GrowthPlanProposed { proposed_by }
  GrowthPlanAgreed { agreed_by_person, agreed_by_manager }
  GrowthPlanAgreementRevoked { reason, revoked_by }

Check-ins:
  CheckInRecorded { id, date, focus_areas_discussed, progress_notes,
                    feedback_provided, next_steps, recorded_by }
  CheckInAmended { check_in_id, field, old_value, new_value, amended_by, reason }

Quarterly reviews:
  QuarterlyReviewCompleted { review_notes, outcomes, next_quarter_direction, reviewed_by }
  GrowthPlanSuperseded { superseded_by_reason }

Framework migration:
  FrameworkVersionMigrated { framework_id, old_version, new_version, mappings: [
    { from_stable_id, to_stable_id, mapping_type, requires_reassessment,
      from_capability_name, to_capability_name,
      counts: { ratings, evidence, comments } }, ... ] }
    — implemented in PR #119. Versions are integers (not UUIDs);
      `mappings` (not `capability_mappings`) carries per-mapping counts
      so projections and the activity feed need no extra joins.
    — COMPLETED ASSESSMENTS ARE FROZEN from migration (ADR-19): the aggregate
      refuses to migrate once alignment is completed; FrameworkVersionMigrationSync
      skips aligned participants; and CurrentAssessment#handle_framework_version_migrated
      skips re-keying/flagging rating rows of any cycle the person has aligned
      (frozen set read from AssessmentCycleProgress, owned by the same
      projection → replay-safe). Migrate-forward applies only to open cycles.
  ReassessmentFlagged { capability_stable_id, reason }
    — not yet emitted; flagging is currently done in-place via
      `AssessmentLevelRating.migration_status = "flagged"` on the
      handler. A dedicated event may be introduced when the
      relink/dismiss UI ships.
  ReassessmentResolved { capability_stable_id, resolution, resolved_by }
    — deferred; resolution UI not implemented.
  ArchivedCapabilityAcknowledged { capability_stable_id, action, relinked_to_stable_id? }
    action: relinked | dismissed
    — deferred; UI not implemented.
```

---

## Projections

All projection read models have `tenant_id` and `acts_as_tenant :tenant`.

### Current Assessment State

Per-level frequency ratings per capability. One row per `(person, framework, capability_stable_id, level_ordinal)`. Updated synchronously on rating events.

```ruby
# assessment_level_ratings table:
#   id, tenant_id, person_id, framework_id, capability_stable_id, level_ordinal,
#   self_rated_frequency, manager_rated_frequency, aligned_frequency,
#   self_rated_comment, manager_rated_comment, aligned_comment,
#   last_self_rated_at, last_manager_rated_at, last_aligned_at,
#   manager_rated_by_id, aligned_by_id,            # actor attribution (ADR-18)
#   source (human | seeded | agent), seeded_from_cycle_id,
#   migration_status, reassessment_reason
#
# assessment_cycle_progress also carries: aligned_framework_version (ADR-19).
# assessment_cycle_enrollments carries the per-cycle assessed-level snapshot:
#   role_id, level_id, level_ordinal (owned by AssessmentCycles::Projections::
#   CurrentState; read by scoring instead of the live assignment level — ADR-19).
#
# Effective frequency fallback: aligned → manager → self → default
#   default: 1.0 for level_ordinal <= person_level (assume consistent)
#            0.0 for level_ordinal >  person_level (not expected)
#   person_level = the cycle's ASSESSED level (enrollment snapshot), not the
#                  person's live assignment level (ADR-19).
#
# Agreed level: derived as max(level_ordinal where effective_frequency == "consistent")
#               Never stored — computed on demand by PersonDevelopment::Scoring
```

### Growth Plan State

Current goal, focus areas, last check-in. Updated synchronously.

```ruby
# growth_plan_states table:
#   id, tenant_id, person_id, framework_id, goal, goal_type,
#   target_date, status, agreed_at, last_check_in_at
# growth_plan_focus_areas table:
#   id, tenant_id, growth_plan_state_id, capability_stable_id,
#   title, gap_identified, success_criteria, action_plan,
#   action_type, status, ordinal
```

### Evidence Collection

All evidence for a person. Updated synchronously.

```ruby
# evidence_items table:
#   id, tenant_id, person_id, framework_id, capability_stable_id, level_ordinal,
#   source, evidence_type, custom_type_label, title, content,
#   external_reference (jsonb: system, url?, external_id?, metadata?),
#   author_id, cycle_id, link_status (active|withdrawn),
#   withdrawn_at, withdrawn_by_id, withdrawal_reason,
#   edited_at, edited_by_id,
#   recorded_at, created_at, updated_at
#
# evidence_requests table:
#   id, tenant_id, person_id, framework_id, requested_by_id, requestee_person_id,
#   capability_stable_id, level_ordinal, cycle_id, message, due_at,
#   status (pending|responded|declined|cancelled), evidence_id,
#   responded_at, declined_at, decline_reason, cancelled_at,
#   reminder_history, last_reminded_at, created_at, updated_at
#
# cycle_id is nullable for records created outside a cycle and legacy projections.
# Cycle attribution is not changed by later evidence-link events.
```

### Assessment Authority

Reporting line + manager-rating delegations. Owned exclusively by
`PersonDevelopment::Projections::AssessmentAuthority` (a dedicated projection,
NOT folded into Current Assessment State, so it can be added without bumping
that projection's CODE_VERSION). Read by `AssessmentPolicy` and the activity
feed.

```ruby
# recorded_reporting_managers table (one row per tenant × person × framework):
#   id, tenant_id, person_id, framework_id, manager_id, source (hris|backfill)
#   → RecordedReportingManager.manager_id_for(person_id, framework_id)

# manager_assessment_delegations table
#   (one row per tenant × person × framework × delegate_person_id):
#   id, tenant_id, person_id, framework_id, delegate_person_id, granted_by_id,
#   revoked_by_id, status (active|revoked), reason, expires_at, revoked_at
#   → scope .active = status "active" AND (expires_at IS NULL OR expires_at > now)
#   → ManagerAssessmentDelegation.active_delegate?(person_id:, framework_id:, delegate_person_id:)
```

### Point-in-Time Assessment

Replay to `FullAlignmentCompleted` event. No separate projection needed — it's on-demand replay.

### Lifecycle Timeline

The read models keep only the latest of each milestone: `AlignmentReopened`
clears `aligned_at`, and the next `FullAlignmentCompleted` overwrites it.
`Assessments::LifecycleTimeline` reads the stream on demand for the full
record — every join, leave and conclude, alignment start, completion and
re-open per role, role/level and reporting-manager change, exploration and
rating delegation — and `assessments_timeline` serves it over MCP. No
projection: it reads one stream filtered to the milestone types, and reading
the events keeps every historical shape in play. A cycle's home role there is
the aggregate's `@home_role_id` (the role held at `JoinedAssessmentCycle`,
moved by `PersonRoleChanged` until the cycle's first `AlignmentStarted`), so a
role-less alignment event is that role's.

### Freshness

Derived from timestamps on above projections. Queryable for dashboards.
