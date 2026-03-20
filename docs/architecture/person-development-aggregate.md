# Person Development Aggregate

> Read this when: working on assessments, evidence, growth plans, alignment conversations, check-ins, framework migration for in-progress assessments; writing person development events, commands, or projections.

One RES stream per person per framework: `tenant-{tenant_id}/PersonDev-{person_id}-{framework_id}`

---

## Events

```
Assignment:
  PersonAssignedToFramework { framework_id, role_id, level_id }
  RoleChanged { old_role_id, new_role_id, old_level_id, new_level_id, reason }

Evidence:
  EvidenceRecorded { id, capability_stable_id, level_id, source, evidence_type,
                     custom_type_label?, title?, content, external_reference?, author_id }
    source: self | manager | peer
    evidence_type: peer_feedback | project_outcome | code_review | design_review |
                   customer_feedback | incident_response | presentation | mentoring | other
    external_reference: { system, url?, external_id?, metadata? }
  EvidenceRelinked { evidence_id, old_capability_stable_id, old_level_id,
                     new_capability_stable_id, new_level_id, relinked_by, rationale }
  EvidenceWithdrawn { evidence_id, reason, withdrawn_by }

Assessment cycle:
  AssessmentCycleOpened { cycle_id, cycle_name, cycle_type, framework_version_id }
    cycle_type: regular | performance_review | promotion_review
  AssessmentCycleCompleted { cycle_id }

Self-assessment:
  SelfRated { capability_stable_id, level_ordinal, frequency, comment }
    frequency: "some" (0.25×) | "occasional" (0.5×) | "consistent" (1.0×)
  SelfRatingRevised { capability_stable_id, level_ordinal, frequency, comment, rationale }
  SelfRatingCleared { capability_stable_id, level_ordinal }
    → Removes a self-rating (untoggle). Projection nils the frequency on the read model.
      Scoring falls back to the default for that cell.

Manager assessment:
  ManagerRated { capability_stable_id, level_ordinal, frequency, comment }
  ManagerRatingRevised { capability_stable_id, level_ordinal, frequency, comment, rationale }

Alignment:
  AlignmentConversationStarted { cycle_id, mode, started_by }
    mode: async | live | record_only
  AlignmentCommentAdded { capability_stable_id, author_id, content }
  AssessmentAligned { capability_stable_id, level_ordinal, aligned_frequency, comment }
    ← Agreed frequency at a specific level. Agreed level is DERIVED (never stored):
      max(level_ordinal where aligned_frequency == "consistent").
  FullAlignmentCompleted { cycle_id, summary_notes }
    ← SNAPSHOT POINT. All capabilities aligned for this cycle.

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
  FrameworkVersionMigrated { old_version_id, new_version_id, capability_mappings }
  ReassessmentFlagged { capability_stable_id, reason }
  ReassessmentResolved { capability_stable_id, resolution, resolved_by }
  ArchivedCapabilityAcknowledged { capability_stable_id, action, relinked_to_stable_id? }
    action: relinked | dismissed
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
#   source (human | agent), migration_status, reassessment_reason
#
# Effective frequency fallback: aligned → manager → self → default
#   default: 1.0 for level_ordinal <= person_level (assume consistent)
#            0.0 for level_ordinal >  person_level (not expected)
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
#   id, tenant_id, person_id, framework_id, capability_stable_id, level_id,
#   source, evidence_type, custom_type_label, title, content,
#   external_ref_system, external_ref_url, external_ref_id, external_ref_metadata,
#   author_id, link_status (active|superseded), created_at
```

### Point-in-Time Assessment

Replay to `FullAlignmentCompleted` event. No separate projection needed — it's on-demand replay.

### Freshness

Derived from timestamps on above projections. Queryable for dashboards.
