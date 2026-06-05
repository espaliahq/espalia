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
# `id` is excluded by default because most read-model tables use
# `gen_random_uuid()` to auto-generate primary keys — that PK is
# non-deterministic across replays, but every table preserves a stable
# natural identifier (`cycle_id`, `framework_id`, `(cycle_id, person_id)`,
# etc.) which keeps content unique. For tables where the projection
# explicitly assigns the row PK from event data (e.g. `EvidenceItem`
# sets `id: event.data[:evidence_id]`), opt in via `natural_key_is_id: true`.
module ProjectionReplayHelpers
  def snapshot_read_models(projection_class, tenant)
    ActsAsTenant.with_tenant(tenant) do
      case projection_class.name
      when "PersonDevelopment::Projections::EvidenceCollection"
        { evidence_items: rows(EvidenceItem, natural_key_is_id: true) }

      when "PersonDevelopment::Projections::CommentThread"
        {
          person_development_comments: rows(PersonDevelopmentComment, natural_key_is_id: true)
        }

      when "PersonDevelopment::Projections::AssessmentAuthority"
        {
          recorded_reporting_managers:    rows(RecordedReportingManager),
          manager_assessment_delegations: rows(ManagerAssessmentDelegation)
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

      when "PersonDevelopment::Projections::CurrentAssessment"
        {
          assignments:              rows(PersonFrameworkAssignment),
          assessment_level_ratings: rows(AssessmentLevelRating),
          progress:                 rows(AssessmentCycleProgress)
        }

      when "AssessmentCycles::Projections::CurrentState"
        {
          cycles:                   rows(AssessmentCycle),
          enrollments:              rows(AssessmentCycleEnrollment)
        }

      else
        raise ArgumentError, "No snapshot rule for #{projection_class.name} — add it to #{__FILE__}"
      end
    end
  end

  private

  IGNORED_COLUMNS = %w[created_at updated_at].freeze
  ID_COLUMN       = "id"

  def rows(scope, natural_key_is_id: false)
    ignored = IGNORED_COLUMNS + (natural_key_is_id ? [] : [ ID_COLUMN ])
    scope.all.map { |r| r.attributes.except(*ignored) }.sort_by { |attrs| attrs.to_json }
  end
end
