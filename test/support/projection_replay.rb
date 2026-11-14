# frozen_string_literal: true

# Test helpers for round-trip projection rebuild tests.
#
# `snapshot_read_models(projection_class, tenant)` captures every row of
# every read model the projection writes, sorted into a deterministic
# canonical order. The round-trip test compares before/after snapshots to
# assert that `reset!` + replay produces the same read-model state as
# live event handling.
#
# Dispatched per projection class — each projection knows its own owned
# read models. Drift between `reset!` and this helper IS the bug we want
# to catch, so the matching pair must be updated together when read models
# evolve.
#
# `id` is excluded by default because some read-model tables still mint a
# random PK at projection time — that PK is non-deterministic across replays,
# but every table preserves a stable natural identifier (`cycle_id`,
# `framework_id`, `(cycle_id, person_id)`, etc.) which keeps content unique.
#
# For tables whose PK IS rebuild-stable — either set explicitly from event
# data (`EvidenceItem` ← `event.data[:evidence_id]`) or derived
# deterministically from the natural key ({DeterministicId}, e.g.
# `PersonFrameworkAssignment`, `ManagerAssessmentDelegation`) — opt in via
# `stable_id: true`. The round-trip test then asserts the PK is reproduced
# identically across `reset!` + replay, so a regression (a reverted concern,
# a random PK on a new externally-addressable table) fails CI rather than
# silently reissuing externally-referenced ids.
module ProjectionReplayHelpers
  def snapshot_read_models(projection_class, tenant)
    ActsAsTenant.with_tenant(tenant) do
      case projection_class.name
      when "PersonDevelopment::Projections::EvidenceCollection"
        {
          evidence_items: rows(EvidenceItem, stable_id: true),
          # evidence_links uses a gen-style PK; its natural key is
          # (evidence_id, capability_stable_id, level_ordinal).
          evidence_links: rows(EvidenceLink)
        }

      when "PersonDevelopment::Projections::CommentThread"
        {
          person_development_comments: rows(PersonDevelopmentComment, stable_id: true)
        }

      when "PersonDevelopment::Projections::EvidenceRequests"
        {
          # PK is the event-carried request_id — assert it survives reset! + replay.
          evidence_requests: rows(EvidenceRequest, stable_id: true)
        }

      when "PersonDevelopment::Projections::AssessmentAuthority"
        {
          recorded_reporting_managers:    rows(RecordedReportingManager),
          # PK derived deterministically from the natural key — assert it
          # survives reset! + replay (DeterministicId).
          manager_assessment_delegations: rows(ManagerAssessmentDelegation, stable_id: true)
        }

      when "Frameworks::Projections::PublishedState"
        {
          frameworks:               rows(FrameworkState::Framework),
          role_families:            rows(FrameworkState::RoleFamily),
          roles:                    rows(FrameworkState::Role),
          levels:                   rows(FrameworkState::Level),
          capability_categories:    rows(FrameworkState::CapabilityCategory),
          capabilities:             rows(FrameworkState::Capability),
          bindings:                 rows(FrameworkState::CapabilityRoleBinding),
          expectations:             rows(FrameworkState::BehaviouralExpectation),
          illustrations:            rows(FrameworkState::RoleIllustration),
          suggested_edits:          rows(FrameworkState::SuggestedEdit),
          collaborators:            rows(FrameworkState::Collaborator),
          migration_mappings:       rows(FrameworkState::MigrationMapping)
        }

      when "Frameworks::Projections::SuggestionThread"
        {
          # PK is the event-carried comment_id — assert it survives reset! + replay.
          framework_suggestion_comments: rows(FrameworkState::SuggestionComment, stable_id: true)
        }

      when "PersonDevelopment::Projections::CurrentAssessment"
        {
          # PK derived deterministically from (person_id, framework_id) —
          # assert it survives reset! + replay (DeterministicId).
          assignments:              rows(PersonFrameworkAssignment, stable_id: true),
          assessment_level_ratings: rows(AssessmentLevelRating),
          progress:                 rows(AssessmentCycleProgress),
          # PK derived from (cycle_id, person_id, role_id) — DeterministicId.
          role_alignments:          rows(AssessmentCycleRoleAlignment, stable_id: true),
          # PK is the event-carried exploration_id.
          explorations:             rows(AssessmentExploration, stable_id: true)
        }

      when "AssessmentCycles::Projections::CurrentState"
        {
          cycles:                   rows(AssessmentCycle),
          enrollments:              rows(AssessmentCycleEnrollment, stable_id: true)
        }

      when "AssessmentCycles::Projections::CalibrationSessions"
        {
          # PK is the event-carried session_id — assert it survives reset! + replay.
          sessions: rows(CalibrationSession, stable_id: true),
          members:  rows(CalibrationSessionMember)
        }

      when "OrgGraph::Projections::Structure"
        {
          # Level and unit PKs are event-carried ids — assert they survive reset! + replay.
          taxonomy_levels: rows(OrgTaxonomyLevel, stable_id: true),
          units:           rows(OrgUnit, stable_id: true),
          fact_providers:  rows(OrgFactProvider, stable_id: true),
          unit_owners:     rows(OrgUnitOwner, stable_id: true),
          # A link's natural key is (succession_id, predecessor_id, successor_id).
          successions:     rows(OrgUnitSuccession)
        }

      when "OrgGraph::Projections::Members"
        # The PK derives from the person and the unit — assert it survives reset! + replay.
        { memberships: rows(OrgMembership, stable_id: true) }

      when "OrgGraph::Projections::PeopleColumns"
        # Only the projected columns; the sync owns the rest of the row.
        { people: rows(Person.select(:id, *OrgGraph::Projections::PeopleColumns::COLUMNS), stable_id: true) }
      when "OrgGraph::Projections::FactAges"
        # The PK derives from the person and the fact — assert it survives reset! + replay.
        { fact_ages: rows(OrgFactAge, stable_id: true) }

      when "OrgGraph::Projections::UnitActivity"
        # The PK derives from the event and the unit — assert it survives reset! + replay.
        { unit_activities: rows(OrgUnitActivity, stable_id: true) }
      when "OrgGraph::Projections::Leavers"
        # The PK derives from the person — assert it survives reset! + replay.
        { leavers: rows(OrgLeaver, stable_id: true) }
      when "OrgGraph::Projections::History"
        # A row's natural key is its subject, fact, key, period and learned window.
        { fact_periods: rows(OrgFactPeriod) }
      when "TeamPlanning::Projections::Plans"
        # The PK is the event's plan id — assert it survives reset! + replay.
        { plans: rows(TeamPlanningPlan, stable_id: true) }

      else
        raise ArgumentError, "No snapshot rule for #{projection_class.name} — add it to #{__FILE__}"
      end
    end
  end

  private

  IGNORED_COLUMNS = %w[created_at updated_at].freeze
  ID_COLUMN       = "id"

  def rows(scope, stable_id: false)
    ignored = IGNORED_COLUMNS + (stable_id ? [] : [ ID_COLUMN ])
    scope.all.map { |r| r.attributes.except(*ignored) }.sort_by { |attrs| attrs.to_json }
  end
end
