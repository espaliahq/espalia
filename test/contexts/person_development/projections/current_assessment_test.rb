# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/projection_replay"

class PersonDevelopment::Projections::CurrentAssessmentTest < ActiveSupport::TestCase
  include ProjectionReplayHelpers

  setup do
    @tenant = create(:tenant)
    @projection = PersonDevelopment::Projections::CurrentAssessment.new
    @person_id = SecureRandom.uuid_v7
    @framework_id = SecureRandom.uuid_v7
    @cycle_id = SecureRandom.uuid_v7

    # Create a cycle + enrollment row (CurrentState's responsibility, faked
    # here via factory) and an empty progress row so the journey handlers
    # have something to update.
    ActsAsTenant.with_tenant(@tenant) do
      @cycle = create(:assessment_cycle,
        tenant: @tenant, cycle_id: @cycle_id, framework_id: @framework_id, framework_version: 1)
      @enrollment = create(:assessment_cycle_enrollment,
        tenant: @tenant, cycle: @cycle, person_id: @person_id)
      @progress = create(:assessment_cycle_progress,
        tenant: @tenant, cycle: @cycle, person_id: @person_id)
    end
  end

  context "PersonAssignedToFramework" do
    should "create a PersonFrameworkAssignment row" do
      role_id = SecureRandom.uuid_v7
      level_id = SecureRandom.uuid_v7

      emit(PersonDevelopment::Events::PersonAssignedToFramework,
        person_id: @person_id, framework_id: @framework_id,
        role_id: role_id, level_id: level_id)

      ActsAsTenant.with_tenant(@tenant) do
        assignment = PersonFrameworkAssignment.find_by(
          person_id: @person_id, framework_id: @framework_id
        )
        assert_not_nil assignment
        assert_equal role_id, assignment.role_id
        assert_equal level_id, assignment.level_id
      end
    end
  end

  context "PersonRoleChanged" do
    should "update both role_id and level_id on the assignment" do
      original_role = SecureRandom.uuid_v7
      original_level = SecureRandom.uuid_v7
      new_role = SecureRandom.uuid_v7
      new_level = SecureRandom.uuid_v7

      emit(PersonDevelopment::Events::PersonAssignedToFramework,
        person_id: @person_id, framework_id: @framework_id,
        role_id: original_role, level_id: original_level)

      emit(PersonDevelopment::Events::PersonRoleChanged,
        previous_role_id: original_role, new_role_id: new_role,
        previous_level_id: original_level, new_level_id: new_level,
        reason: "hris_sync")

      ActsAsTenant.with_tenant(@tenant) do
        assignment = PersonFrameworkAssignment.find_by(
          person_id: @person_id, framework_id: @framework_id
        )
        assert_equal new_role, assignment.role_id
        assert_equal new_level, assignment.level_id
      end
    end
  end

  context "PersonLevelChanged" do
    should "update only level_id on the assignment" do
      role = SecureRandom.uuid_v7
      original_level = SecureRandom.uuid_v7
      new_level = SecureRandom.uuid_v7

      emit(PersonDevelopment::Events::PersonAssignedToFramework,
        person_id: @person_id, framework_id: @framework_id,
        role_id: role, level_id: original_level)

      emit(PersonDevelopment::Events::PersonLevelChanged,
        previous_level_id: original_level, new_level_id: new_level,
        reason: "hris_sync")

      ActsAsTenant.with_tenant(@tenant) do
        assignment = PersonFrameworkAssignment.find_by(
          person_id: @person_id, framework_id: @framework_id
        )
        assert_equal role, assignment.role_id
        assert_equal new_level, assignment.level_id
      end
    end
  end

  context "JoinedAssessmentCycle / LeftAssessmentCycle" do
    should "be no-ops on the PersonFrameworkAssignment (participant is authoritative)" do
      role_id = SecureRandom.uuid_v7
      level_id = SecureRandom.uuid_v7

      emit(PersonDevelopment::Events::PersonAssignedToFramework,
        person_id: @person_id, framework_id: @framework_id,
        role_id: role_id, level_id: level_id)
      emit(PersonDevelopment::Events::JoinedAssessmentCycle,
        cycle_id: @cycle_id, framework_version: 1)
      emit(PersonDevelopment::Events::LeftAssessmentCycle,
        cycle_id: @cycle_id, reason: "manual")

      # No cycle fields exist on PersonFrameworkAssignment — just assert that the row is stable
      ActsAsTenant.with_tenant(@tenant) do
        assignment = PersonFrameworkAssignment.find_by(
          person_id: @person_id, framework_id: @framework_id
        )
        assert_not_nil assignment
      end
    end

    should "wipe stale AssessmentLevelRating rows when a cycle is re-joined" do
      cap_sid = SecureRandom.uuid_v7

      # Simulate a prior enrolment with a manager+self rating recorded.
      ActsAsTenant.with_tenant(@tenant) do
        AssessmentLevelRating.create!(
          tenant: @tenant, cycle_id: @cycle_id, person_id: @person_id,
          framework_id: @framework_id,
          capability_stable_id: cap_sid, level_ordinal: 2,
          self_rated_frequency: "consistent",
          manager_rated_frequency: "consistent",
          aligned_frequency: "consistent",
          source: "human"
        )
      end

      # Re-joining the same cycle (after unenroll → re-enroll) wipes the row
      # so the read model matches the aggregate's reset in-memory state.
      emit(PersonDevelopment::Events::JoinedAssessmentCycle,
        cycle_id: @cycle_id, framework_version: 1)

      ActsAsTenant.with_tenant(@tenant) do
        assert_nil AssessmentLevelRating.find_by(
          cycle_id: @cycle_id, person_id: @person_id,
          capability_stable_id: cap_sid, level_ordinal: 2
        )
      end
    end

    should "preserve the progress row as a historical record on LeftAssessmentCycle" do
      # Establish journey state — joined, then started by recording a rating.
      emit(PersonDevelopment::Events::JoinedAssessmentCycle,
        cycle_id: @cycle_id, framework_version: 1)
      emit(PersonDevelopment::Events::SelfRated,
        cycle_id: @cycle_id, capability_stable_id: SecureRandom.uuid_v7,
        level_ordinal: 2, frequency: "consistent", source: "human")

      progress_before = ActsAsTenant.with_tenant(@tenant) do
        AssessmentCycleProgress.find_by(cycle_id: @cycle_id, person_id: @person_id)
      end
      assert_not_nil progress_before
      assert_equal "started", progress_before.status
      assert_not_nil progress_before.started_at

      emit(PersonDevelopment::Events::LeftAssessmentCycle,
        cycle_id: @cycle_id, reason: "manual")

      # Row is retained; columns are untouched. CurrentState flips the
      # enrollment side to `withdrawn`; CurrentAssessment intentionally
      # leaves progress as a historical record of how far the person got.
      ActsAsTenant.with_tenant(@tenant) do
        progress_after = AssessmentCycleProgress.find_by(
          cycle_id: @cycle_id, person_id: @person_id
        )
        assert_not_nil progress_after, "progress row must be preserved on LeftAssessmentCycle"
        assert_equal "started", progress_after.status
        assert_equal progress_before.started_at, progress_after.started_at
      end
    end
  end

  context "SelfRated" do
    should "create an AssessmentLevelRating row with cycle_id" do
      cap_sid = SecureRandom.uuid_v7

      emit(PersonDevelopment::Events::SelfRated,
        capability_stable_id: cap_sid, level_ordinal: 3, frequency: "consistent",
        cycle_id: @cycle_id, comment: "Good")

      ActsAsTenant.with_tenant(@tenant) do
        rating = AssessmentLevelRating.find_by(
          cycle_id: @cycle_id,
          person_id: @person_id,
          framework_id: @framework_id,
          capability_stable_id: cap_sid,
          level_ordinal: 3
        )
        assert_not_nil rating
        assert_equal "consistent", rating.self_rated_frequency
        assert_equal "Good", rating.self_rated_comment
        assert_not_nil rating.last_self_rated_at
      end
    end

    should "set progress started_at + status on first rating" do
      cap_sid = SecureRandom.uuid_v7

      emit(PersonDevelopment::Events::SelfRated,
        capability_stable_id: cap_sid, level_ordinal: 3, frequency: "some",
        cycle_id: @cycle_id, comment: nil)

      ActsAsTenant.with_tenant(@tenant) do
        progress = AssessmentCycleProgress.find_by(cycle_id: @cycle_id, person_id: @person_id)
        assert_not_nil progress.started_at
        assert_equal "started", progress.status
      end
    end

    should "create separate rows across cycles" do
      cap_sid = SecureRandom.uuid_v7
      other_cycle_id = SecureRandom.uuid_v7

      # Close the first cycle so the partial unique "one open per framework" allows
      # a second cycle against the same framework. This mirrors what happens in
      # production: consecutive cycles against the same framework.
      ActsAsTenant.with_tenant(@tenant) do
        @cycle.update!(status: "closed", closed_at: Time.current)
        create(:assessment_cycle, tenant: @tenant, cycle_id: other_cycle_id, framework_id: @framework_id)
      end

      emit(PersonDevelopment::Events::SelfRated,
        capability_stable_id: cap_sid, level_ordinal: 3, frequency: "some",
        cycle_id: @cycle_id, comment: nil)
      emit(PersonDevelopment::Events::SelfRated,
        capability_stable_id: cap_sid, level_ordinal: 3, frequency: "consistent",
        cycle_id: other_cycle_id, comment: nil)

      ActsAsTenant.with_tenant(@tenant) do
        assert_equal 2, AssessmentLevelRating.where(
          person_id: @person_id,
          framework_id: @framework_id,
          capability_stable_id: cap_sid,
          level_ordinal: 3
        ).count

        first = AssessmentLevelRating.find_by(cycle_id: @cycle_id, capability_stable_id: cap_sid)
        second = AssessmentLevelRating.find_by(cycle_id: other_cycle_id, capability_stable_id: cap_sid)
        assert_equal "some", first.self_rated_frequency
        assert_equal "consistent", second.self_rated_frequency
      end
    end
  end

  context "SelfRatingRevised" do
    should "update the existing AssessmentLevelRating row in the same cycle" do
      cap_sid = SecureRandom.uuid_v7

      emit(PersonDevelopment::Events::SelfRated,
        capability_stable_id: cap_sid, level_ordinal: 3, frequency: "some",
        cycle_id: @cycle_id, comment: nil)
      emit(PersonDevelopment::Events::SelfRatingRevised,
        capability_stable_id: cap_sid, level_ordinal: 3, frequency: "consistent",
        cycle_id: @cycle_id, comment: "Reconsidered", rationale: "Growth")

      ActsAsTenant.with_tenant(@tenant) do
        assert_equal 1, AssessmentLevelRating.where(
          cycle_id: @cycle_id,
          person_id: @person_id,
          capability_stable_id: cap_sid
        ).count
        rating = AssessmentLevelRating.find_by(
          cycle_id: @cycle_id, person_id: @person_id,
          capability_stable_id: cap_sid, level_ordinal: 3
        )
        assert_equal "consistent", rating.self_rated_frequency
      end
    end
  end

  context "ManagerRated" do
    should "set manager_rated_frequency on a new per-cycle row" do
      cap_sid = SecureRandom.uuid_v7

      emit(PersonDevelopment::Events::ManagerRated,
        capability_stable_id: cap_sid, level_ordinal: 3, frequency: "occasional",
        cycle_id: @cycle_id, comment: "Room to grow")

      ActsAsTenant.with_tenant(@tenant) do
        rating = AssessmentLevelRating.find_by(
          cycle_id: @cycle_id, person_id: @person_id,
          capability_stable_id: cap_sid, level_ordinal: 3
        )
        assert_not_nil rating
        assert_equal "occasional", rating.manager_rated_frequency
        assert_equal "Room to grow", rating.manager_rated_comment
      end
    end

    should "record manager_rated_by_id from the event's rated_by_id" do
      cap_sid = SecureRandom.uuid_v7
      rater_id = SecureRandom.uuid_v7

      emit(PersonDevelopment::Events::ManagerRated,
        capability_stable_id: cap_sid, level_ordinal: 3, frequency: "occasional",
        cycle_id: @cycle_id, comment: nil, rated_by_id: rater_id)

      ActsAsTenant.with_tenant(@tenant) do
        rating = AssessmentLevelRating.find_by(
          cycle_id: @cycle_id, person_id: @person_id,
          capability_stable_id: cap_sid, level_ordinal: 3
        )
        assert_equal rater_id, rating.manager_rated_by_id
      end
    end

    should "update progress started_at on first rating of any kind" do
      emit(PersonDevelopment::Events::ManagerRated,
        capability_stable_id: SecureRandom.uuid_v7, level_ordinal: 3,
        frequency: "some", cycle_id: @cycle_id, comment: nil)

      ActsAsTenant.with_tenant(@tenant) do
        progress = AssessmentCycleProgress.find_by(cycle_id: @cycle_id, person_id: @person_id)
        assert_equal "started", progress.status
      end
    end
  end

  context "ManagerRatingCleared" do
    should "clear manager_rated_frequency on the per-cycle row" do
      cap_sid = SecureRandom.uuid_v7

      emit(PersonDevelopment::Events::ManagerRated,
        capability_stable_id: cap_sid, level_ordinal: 3, frequency: "occasional",
        cycle_id: @cycle_id, comment: "Initial", rated_by_id: SecureRandom.uuid_v7)
      emit(PersonDevelopment::Events::ManagerRatingCleared,
        capability_stable_id: cap_sid, level_ordinal: 3, cycle_id: @cycle_id)

      ActsAsTenant.with_tenant(@tenant) do
        rating = AssessmentLevelRating.find_by(
          cycle_id: @cycle_id, person_id: @person_id,
          capability_stable_id: cap_sid, level_ordinal: 3
        )
        assert_nil rating.manager_rated_frequency
        assert_nil rating.manager_rated_by_id, "clearing should also drop the rater attribution"
      end
    end
  end

  context "seeded ratings" do
    should "stamp source=seeded and seeded_from_cycle_id when SelfRated carries source: 'seeded'" do
      cap_sid = SecureRandom.uuid_v7
      prior_cycle_id = SecureRandom.uuid_v7

      emit(PersonDevelopment::Events::SelfRated,
        capability_stable_id: cap_sid, level_ordinal: 2, frequency: "consistent",
        cycle_id: @cycle_id, source: "seeded", seeded_from_cycle_id: prior_cycle_id)

      ActsAsTenant.with_tenant(@tenant) do
        rating = AssessmentLevelRating.find_by(
          cycle_id: @cycle_id, person_id: @person_id,
          capability_stable_id: cap_sid, level_ordinal: 2
        )
        assert_equal "seeded", rating.source
        assert_equal prior_cycle_id, rating.seeded_from_cycle_id
        assert_equal "consistent", rating.self_rated_frequency
      end
    end

    should "NOT touch progress.started_at on a seeded SelfRated" do
      cap_sid = SecureRandom.uuid_v7
      emit(PersonDevelopment::Events::SelfRated,
        capability_stable_id: cap_sid, level_ordinal: 2, frequency: "consistent",
        cycle_id: @cycle_id, source: "seeded", seeded_from_cycle_id: SecureRandom.uuid_v7)

      ActsAsTenant.with_tenant(@tenant) do
        progress = AssessmentCycleProgress.find_by(cycle_id: @cycle_id, person_id: @person_id)
        assert_equal "in_progress", progress.status
        assert_nil progress.started_at
      end
    end

    should "flip source back to 'human' when a seeded rating is revised by the user" do
      cap_sid = SecureRandom.uuid_v7
      prior_cycle_id = SecureRandom.uuid_v7

      emit(PersonDevelopment::Events::SelfRated,
        capability_stable_id: cap_sid, level_ordinal: 2, frequency: "consistent",
        cycle_id: @cycle_id, source: "seeded", seeded_from_cycle_id: prior_cycle_id)
      emit(PersonDevelopment::Events::SelfRatingRevised,
        capability_stable_id: cap_sid, level_ordinal: 2, frequency: "occasional",
        cycle_id: @cycle_id, rationale: "downgrade")

      ActsAsTenant.with_tenant(@tenant) do
        rating = AssessmentLevelRating.find_by(
          cycle_id: @cycle_id, person_id: @person_id,
          capability_stable_id: cap_sid, level_ordinal: 2
        )
        assert_equal "human", rating.source
        assert_equal prior_cycle_id, rating.seeded_from_cycle_id, "seeded_from_cycle_id should remain for audit"
      end
    end
  end

  context "AlignmentStarted" do
    should "flip progress status to aligning and stamp the started_by_id" do
      manager = ActsAsTenant.with_tenant(@tenant) { create(:person, tenant: @tenant, name: "Mgr") }

      emit(PersonDevelopment::Events::AlignmentStarted,
        cycle_id: @cycle_id, started_by_id: manager.id)

      ActsAsTenant.with_tenant(@tenant) do
        progress = AssessmentCycleProgress.find_by(cycle_id: @cycle_id, person_id: @person_id)
        assert_equal "aligning", progress.status
        assert_not_nil progress.alignment_started_at
        assert_equal manager.id, progress.alignment_started_by_id
      end
    end
  end

  context "FullAlignmentCompleted" do
    should "flip progress status to aligned and stamp completed_by_id" do
      manager = ActsAsTenant.with_tenant(@tenant) { create(:person, tenant: @tenant, name: "Mgr") }

      emit(PersonDevelopment::Events::FullAlignmentCompleted,
        cycle_id: @cycle_id, completed_by_id: manager.id)

      ActsAsTenant.with_tenant(@tenant) do
        progress = AssessmentCycleProgress.find_by(cycle_id: @cycle_id, person_id: @person_id)
        assert_equal "aligned", progress.status
        assert_not_nil progress.aligned_at
        assert_equal manager.id, progress.aligned_by_id
      end
    end
  end

  context "AssessmentAligned" do
    should "set aligned_frequency on the row without changing progress status" do
      cap_sid = SecureRandom.uuid_v7

      emit(PersonDevelopment::Events::AssessmentAligned,
        capability_stable_id: cap_sid, level_ordinal: 3, aligned_frequency: "consistent",
        cycle_id: @cycle_id, comment: "Agreed")

      ActsAsTenant.with_tenant(@tenant) do
        rating = AssessmentLevelRating.find_by(
          cycle_id: @cycle_id, person_id: @person_id,
          capability_stable_id: cap_sid, level_ordinal: 3
        )
        assert_not_nil rating
        assert_equal "consistent", rating.aligned_frequency

        # Status changes are driven by AlignmentStarted and
        # FullAlignmentCompleted — AssessmentAligned no longer touches
        # progress lifecycle status.
        progress = AssessmentCycleProgress.find_by(cycle_id: @cycle_id, person_id: @person_id)
        assert_not_equal "aligned", progress.status
      end
    end

    should "record aligned_by_id, and clear it on AlignmentCleared" do
      cap_sid = SecureRandom.uuid_v7
      aligner_id = SecureRandom.uuid_v7

      emit(PersonDevelopment::Events::AssessmentAligned,
        capability_stable_id: cap_sid, level_ordinal: 3, aligned_frequency: "consistent",
        cycle_id: @cycle_id, comment: nil, aligned_by_id: aligner_id)

      rating = ActsAsTenant.with_tenant(@tenant) do
        AssessmentLevelRating.find_by(cycle_id: @cycle_id, person_id: @person_id,
          capability_stable_id: cap_sid, level_ordinal: 3)
      end
      assert_equal aligner_id, rating.aligned_by_id

      emit(PersonDevelopment::Events::AlignmentCleared,
        capability_stable_id: cap_sid, level_ordinal: 3, cycle_id: @cycle_id,
        cleared_by_id: SecureRandom.uuid_v7)

      assert_nil rating.reload.aligned_by_id
    end
  end

  context "rebuild contract" do
    should "reset! + replay produces identical read-model state" do
      role_id  = SecureRandom.uuid_v7
      level_id = SecureRandom.uuid_v7
      cap_sid  = SecureRandom.uuid_v7

      append_and_project(PersonDevelopment::Events::PersonAssignedToFramework,
        person_id: @person_id, framework_id: @framework_id,
        role_id: role_id, level_id: level_id)

      append_and_project(PersonDevelopment::Events::JoinedAssessmentCycle,
        person_id: @person_id, framework_id: @framework_id,
        cycle_id: @cycle_id, framework_version: 1)

      append_and_project(PersonDevelopment::Events::SelfRated,
        person_id: @person_id, framework_id: @framework_id,
        cycle_id: @cycle_id, capability_stable_id: cap_sid,
        level_ordinal: 2, frequency: "consistent", source: "human")

      append_and_project(PersonDevelopment::Events::ManagerRated,
        person_id: @person_id, framework_id: @framework_id,
        cycle_id: @cycle_id, capability_stable_id: cap_sid,
        level_ordinal: 2, frequency: "occasional", source: "human")

      before_snapshot = snapshot_read_models(PersonDevelopment::Projections::CurrentAssessment, @tenant)
      assert_equal 1, before_snapshot[:assignments].size
      assert_equal 1, before_snapshot[:assessment_level_ratings].size

      PersonDevelopment::Projections::CurrentAssessment.reset!(tenant: @tenant)
      ActsAsTenant.with_tenant(@tenant) do
        assert_equal 0, PersonFrameworkAssignment.count
        assert_equal 0, AssessmentLevelRating.count
        # Progress is owned by CurrentAssessment — truncated by its reset!
        assert_equal 0, AssessmentCycleProgress.count
        # Enrollment is owned by CurrentState — untouched by this reset!
        assert_equal 1, AssessmentCycleEnrollment.count
      end

      Projections::Replayer.replay(
        projection_class: PersonDevelopment::Projections::CurrentAssessment,
        tenant: @tenant
      )

      after_snapshot = snapshot_read_models(PersonDevelopment::Projections::CurrentAssessment, @tenant)
      assert_equal before_snapshot, after_snapshot
    end
  end

  context "FrameworkVersionMigrated" do
    setup do
      @from_stable_id = SecureRandom.uuid_v7
      @to_stable_id   = SecureRandom.uuid_v7
      emit(PersonDevelopment::Events::PersonAssignedToFramework,
        person_id: @person_id, framework_id: @framework_id,
        role_id: SecureRandom.uuid_v7, level_id: SecureRandom.uuid_v7)
      emit(PersonDevelopment::Events::JoinedAssessmentCycle,
        cycle_id: @cycle_id, framework_version: 1)
    end

    should "re-key rating rows for a same mapping" do
      ActsAsTenant.with_tenant(@tenant) do
        create(:assessment_level_rating, tenant: @tenant,
          person_id: @person_id, framework_id: @framework_id, cycle_id: @cycle_id,
          capability_stable_id: @from_stable_id, level_ordinal: 3,
          self_rated_frequency: "consistent")
      end

      emit(PersonDevelopment::Events::FrameworkVersionMigrated,
        framework_id: @framework_id, old_version: 1, new_version: 2,
        mappings: [ { from_stable_id: @from_stable_id, to_stable_id: @to_stable_id,
                      mapping_type: "same", requires_reassessment: false } ])

      ActsAsTenant.with_tenant(@tenant) do
        assert_nil AssessmentLevelRating.find_by(capability_stable_id: @from_stable_id)
        assert_not_nil AssessmentLevelRating.find_by(capability_stable_id: @to_stable_id)
      end
    end

    should "flag rating rows as evolved when requires_reassessment is true" do
      ActsAsTenant.with_tenant(@tenant) do
        create(:assessment_level_rating, tenant: @tenant,
          person_id: @person_id, framework_id: @framework_id, cycle_id: @cycle_id,
          capability_stable_id: @from_stable_id, level_ordinal: 3,
          self_rated_frequency: "consistent")
      end

      emit(PersonDevelopment::Events::FrameworkVersionMigrated,
        framework_id: @framework_id, old_version: 1, new_version: 2,
        mappings: [ { from_stable_id: @from_stable_id, to_stable_id: @to_stable_id,
                      mapping_type: "evolved", requires_reassessment: true } ])

      ActsAsTenant.with_tenant(@tenant) do
        rating = AssessmentLevelRating.find_by(capability_stable_id: @to_stable_id)
        assert_equal "flagged", rating.migration_status
        assert_equal "expectations_evolved", rating.reassessment_reason
      end
    end

    should "flag archived rating rows without moving them" do
      ActsAsTenant.with_tenant(@tenant) do
        create(:assessment_level_rating, tenant: @tenant,
          person_id: @person_id, framework_id: @framework_id, cycle_id: @cycle_id,
          capability_stable_id: @from_stable_id, level_ordinal: 3,
          self_rated_frequency: "consistent")
      end

      emit(PersonDevelopment::Events::FrameworkVersionMigrated,
        framework_id: @framework_id, old_version: 1, new_version: 2,
        mappings: [ { from_stable_id: @from_stable_id, to_stable_id: nil,
                      mapping_type: "archived", requires_reassessment: false } ])

      ActsAsTenant.with_tenant(@tenant) do
        rating = AssessmentLevelRating.find_by(capability_stable_id: @from_stable_id)
        assert_not_nil rating
        assert_equal "flagged", rating.migration_status
        assert_equal "capability_archived", rating.reassessment_reason
      end
    end
  end

  private

  # Emits an event through the projection with person/framework metadata.
  #
  # @param event_class [Class] the event class
  # @param data [Hash] event data
  def emit(event_class, **data)
    event = event_class.new(
      data: data,
      metadata: {
        tenant_id: @tenant.id,
        person_id: @person_id,
        framework_id: @framework_id
      }
    )
    @projection.call(event)
  end

  # Appends an event to the real store AND calls the projection directly.
  # Uses `append` rather than `publish` so subscribers (especially sync
  # handlers that dispatch domain commands) don't fire. See the round-trip
  # test pattern in `docs/guidelines/event-sourcing.md`.
  def append_and_project(event_class, **data)
    event = event_class.new(
      data: data,
      metadata: {
        tenant_id: @tenant.id,
        person_id: @person_id,
        framework_id: @framework_id
      }
    )
    stream = EventStreamNaming.person_development_stream(@person_id, @framework_id, tenant: @tenant)
    Rails.configuration.event_store.append(event, stream_name: stream)
    @projection.call(event)
  end
end
