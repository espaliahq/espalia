# frozen_string_literal: true

require "test_helper"

class Projections::RegistryTest < ActiveSupport::TestCase
  context "#names" do
    should "list the four replayable projections" do
      assert_equal(
        %w[
          frameworks/published_state
          person_development/current_assessment
          person_development/evidence_collection
          assessment_cycles/current_state
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
        AssessmentCycles::SyncHandlers::AutoEnrollNewAssignments
      ]
      assert_empty(Projections::Registry.classes & forbidden)
    end
  end
end
