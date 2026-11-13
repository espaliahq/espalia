# frozen_string_literal: true

require "test_helper"

class Projections::RegistryTest < ActiveSupport::TestCase
  context "#names" do
    should "list the replayable projections" do
      assert_equal(
        %w[
          frameworks/published_state
          frameworks/suggestion_thread
          person_development/current_assessment
          person_development/evidence_collection
          person_development/evidence_requests
          person_development/comment_thread
          person_development/assessment_authority
          assessment_cycles/current_state
          assessment_cycles/calibration_sessions
          org_graph/structure
          org_graph/members
          org_graph/fact_ages
        ].sort,
        Projections::Registry.names.sort
      )
    end
  end

  context "#fetch" do
    should "resolve a known name to the projection class" do
      assert_equal(
        Frameworks::Projections::PublishedState,
        Projections::Registry.fetch("frameworks/published_state")
      )
    end

    should "raise KeyError on unknown name" do
      assert_raises(KeyError) { Projections::Registry.fetch("does/not/exist") }
    end
  end

  context "registered classes" do
    should "not include sync handlers that dispatch commands" do
      forbidden = [
        AssessmentCycles::SyncHandlers::PersonEnrollmentSync,
        AssessmentCycles::SyncHandlers::AutoEnrollNewAssignments,
        AssessmentCycles::SyncHandlers::FrameworkVersionRollSync,
        AssessmentCycles::SyncHandlers::ParticipantRoleSync,
        AssessmentCycles::SyncHandlers::CalibrationSessionCloseSync,
        AssessmentCycles::SyncHandlers::CalibrationRevisitSync,
        Frameworks::SyncHandlers::FrameworkVersionMigrationSync,
        OrgGraph::SyncHandlers::RetiredUnitMemberships,
        FeedbackExchange::AssignmentRetry
      ]
      assert_empty(Projections::Registry.classes & forbidden)
    end

    should "not include async notification handlers" do
      # Replaying these would re-send every historical notification.
      forbidden = [
        PersonDevelopment::AsyncHandlers::EvidenceRequestNotifier,
        PersonDevelopment::AsyncHandlers::CommentNotifier,
        PersonDevelopment::AsyncHandlers::FeedbackNotifier,
        PersonDevelopment::AsyncHandlers::RatingRevisitNotifier,
        PersonDevelopment::AsyncHandlers::LensAlignmentNotifier,
        PersonDevelopment::AsyncHandlers::ExplorationNotifier,
        PersonDevelopment::AsyncHandlers::PlacementSuggester
      ]
      assert_empty(Projections::Registry.classes & forbidden)
    end
  end
end
