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
    ← assigned_by / changed_by are nil for system-driven HRIS syncs (provenance
      is then the metadata layer: acting_via: :hris + correlation_id). See ADR-18.
    ← migrate_framework_version RAISES if the current cycle's alignment is
      completed — a completed assessment is immutable (ADR-19).

Evidence:
  EvidenceRecorded { id, capability_stable_id, level_id, source, evidence_type,
                     custom_type_label?, title?, content, external_reference?, author_id }
    source: self | manager | peer
    evidence_type: peer_feedback | project_outcome | code_review | design_review |
                   customer_feedback | incident_response | presentation | mentoring | other
    external_reference: { system, url?, external_id?, metadata? }
  EvidenceRelinked { evidence_id, old_capability_stable_id, old_level_id,
                     new_capability_stable_id, new_level_id, relinked_by, rationale }
  EvidenceUpdated { evidence_id, title?, content, evidence_type,
                    custom_type_label?, external_reference?, edited_by_id }
    ← Carries the FULL post-edit value of every mutable field (snapshot, not a
      delta). Mutable scope is strictly the user-correctable content: title,
      content, evidence_type, custom_type_label, external_reference. The
      capability/level coordinate is owned by EvidenceRelinked; source,
      author_id, and recorded_at are identity invariants and never change.
      Authorization is strictly author-only — no admin override — see
      EvidencePolicy#update?.
  EvidenceWithdrawn { evidence_id, reason, withdrawn_by }

Assessment cycle:
  AssessmentCycleOpened { cycle_id, cycle_name, cycle_type, framework_version_id }
    cycle_type: regular | performance_review | promotion_review
  AssessmentCycleCompleted { cycle_id }

Self-assessment:
  SelfRated { capability_stable_id, level_ordinal, frequency, comment, source, seeded_from_cycle_id }
    frequency: "some" (0.25×) | "occasional" (0.5×) | "consistent" (1.0×)
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
                 seeded_from_cycle_id, rated_by_id? }
    Same source / seeded_from_cycle_id semantics as SelfRated.
    ← rated_by_id: the manager who rated (a domain fact — the assessee's manager
      changes over time). nil for "seeded" carry-forwards and historical events.
      Projected to AssessmentLevelRating.manager_rated_by_id. See ADR-18.
  ManagerRatingRevised { capability_stable_id, level_ordinal, frequency, comment, rationale, rated_by_id? }
    ← Like SelfRatingRevised, always flips the row's source back to "human".
  ManagerRatingCleared { capability_stable_id, level_ordinal, cycle_id, rated_by_id? }

Alignment lifecycle (per cycle):
  AlignmentStarted { cycle_id, started_by_id }
    ← Manager-only. Flips participant status to `aligning` and FREEZES self/manager
      ratings for the cycle. Aggregate guard rejects rate_self / rate_as_manager /
      revise_* / clear_* once started until leave_cycle.
    ← The dispatching CommandHandler additionally emits an AssessmentAligned event
      for every (capability × level) cell where both self_rated_frequency and
      manager_rated_frequency are explicitly recorded and equal — all inside the
      same with_person_development block. Default-fallback matches do NOT
      auto-align; only deliberate, recorded agreement counts.
  AssessmentAligned { capability_stable_id, level_ordinal, aligned_frequency, cycle_id, comment, aligned_by_id? }
    ← Per-cell agreed frequency. Requires alignment to have been started.
      Agreed level is DERIVED (never stored): max(level_ordinal where
      aligned_frequency == "consistent").
    ← aligned_by_id: who recorded the agreement (manual = the submitter; the
      cells auto-aligned at start = the manager who started). Projected to
      AssessmentLevelRating.aligned_by_id. See ADR-18.
  AlignmentCleared { capability_stable_id, level_ordinal, cycle_id, cleared_by_id? }
  FullAlignmentCompleted { cycle_id, completed_by_id, framework_version? }
    ← Manager-only. Flips participant status to `aligned` and freezes ALL
      ratings (including aligned values). SNAPSHOT POINT — long streams will
      compress here when snapshotting infrastructure ships.
    ← framework_version: the version this cycle was assessed against at
      completion (join version, advanced by any mid-cycle migration). Projected
      to AssessmentCycleProgress.aligned_framework_version for reporting. A
      completed assessment is immutable as-at-completion — see ADR-19.

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
#   author_id, link_status (active|withdrawn),
#   withdrawn_at, withdrawn_by_id, withdrawal_reason,
#   edited_at, edited_by_id,
#   recorded_at, created_at, updated_at
```

### Point-in-Time Assessment

Replay to `FullAlignmentCompleted` event. No separate projection needed — it's on-demand replay.

### Freshness

Derived from timestamps on above projections. Queryable for dashboards.
