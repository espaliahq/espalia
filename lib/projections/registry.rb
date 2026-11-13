# frozen_string_literal: true

# Single source of truth for replayable projections.
#
# Listed classes MUST implement the projection rebuild contract — see
# [docs/guidelines/event-sourcing.md](docs/guidelines/event-sourcing.md):
#   * constant `PROJECTION_NAME` — stable identifier used in `projection_versions.name`
#   * constant `CODE_VERSION` — bumped when handler logic or `reset!` semantics change
#   * `.handled_events` — Array<Class> of event classes (also the live-subscription set)
#   * `.reset!(tenant:)` — idempotent truncation of every read model the projection writes,
#     scoped to one tenant
#
# Sync cross-stream handlers that DISPATCH commands
# (`AssessmentCycles::SyncHandlers::PersonEnrollmentSync`,
# `AssessmentCycles::SyncHandlers::AutoEnrollNewAssignments`) are deliberately
# excluded — replaying them would re-fire side effects against already-applied
# state.
#
module Projections::Registry
  # Each registered projection owns its read-model tables exclusively
  # (see `docs/guidelines/event-sourcing.md`). Order here is conventional;
  # iteration order is no longer load-bearing for rebuild correctness.
  REPLAYABLE = {
    "frameworks/published_state"             => "Frameworks::Projections::PublishedState",
    "frameworks/suggestion_thread"           => "Frameworks::Projections::SuggestionThread",
    "assessment_cycles/current_state"        => "AssessmentCycles::Projections::CurrentState",
    "assessment_cycles/calibration_sessions" => "AssessmentCycles::Projections::CalibrationSessions",
    "person_development/current_assessment"  => "PersonDevelopment::Projections::CurrentAssessment",
    "person_development/evidence_collection" => "PersonDevelopment::Projections::EvidenceCollection",
    "person_development/evidence_requests"   => "PersonDevelopment::Projections::EvidenceRequests",
    "person_development/comment_thread"      => "PersonDevelopment::Projections::CommentThread",
    "person_development/assessment_authority" => "PersonDevelopment::Projections::AssessmentAuthority",
    "org_graph/structure"                    => "OrgGraph::Projections::Structure"
  }.freeze

  # @return [Array<String>] the registered projection names
  def self.names
    REPLAYABLE.keys
  end

  # @param name [String] a registered projection name
  # @return [Class] the projection class
  # @raise [KeyError] if not registered
  def self.fetch(name)
    REPLAYABLE.fetch(name) do
      raise KeyError, "Unknown projection: #{name.inspect}. Known: #{names.inspect}"
    end.constantize
  end

  # @return [Array<Class>] every registered projection class, resolved
  def self.classes
    REPLAYABLE.values.map(&:constantize)
  end
end
