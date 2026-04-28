# frozen_string_literal: true

require "test_helper"

class PersonDevelopment::Projections::CurrentAssessmentTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @projection = PersonDevelopment::Projections::CurrentAssessment.new
    @person_id = SecureRandom.uuid_v7
    @framework_id = SecureRandom.uuid_v7
    @cycle_id = SecureRandom.uuid_v7

    # Create a cycle + participant so touch_participant_started/mark_participant_aligned
    # have something to update.
    ActsAsTenant.with_tenant(@tenant) do
      @cycle = create(:assessment_cycle,
        tenant: @tenant, cycle_id: @cycle_id, framework_id: @framework_id, framework_version: 1)
      @participant = create(:assessment_cycle_participant,
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

    should "set participant started_at + status on first rating" do
      cap_sid = SecureRandom.uuid_v7

      emit(PersonDevelopment::Events::SelfRated,
        capability_stable_id: cap_sid, level_ordinal: 3, frequency: "some",
        cycle_id: @cycle_id, comment: nil)

      ActsAsTenant.with_tenant(@tenant) do
        participant = AssessmentCycleParticipant.find_by(cycle_id: @cycle_id, person_id: @person_id)
        assert_not_nil participant.started_at
        assert_equal "started", participant.status
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

    should "update participant started_at on first rating of any kind" do
      emit(PersonDevelopment::Events::ManagerRated,
        capability_stable_id: SecureRandom.uuid_v7, level_ordinal: 3,
        frequency: "some", cycle_id: @cycle_id, comment: nil)

      ActsAsTenant.with_tenant(@tenant) do
        participant = AssessmentCycleParticipant.find_by(cycle_id: @cycle_id, person_id: @person_id)
        assert_equal "started", participant.status
      end
    end
  end

  context "ManagerRatingCleared" do
    should "clear manager_rated_frequency on the per-cycle row" do
      cap_sid = SecureRandom.uuid_v7

      emit(PersonDevelopment::Events::ManagerRated,
        capability_stable_id: cap_sid, level_ordinal: 3, frequency: "occasional",
        cycle_id: @cycle_id, comment: "Initial")
      emit(PersonDevelopment::Events::ManagerRatingCleared,
        capability_stable_id: cap_sid, level_ordinal: 3, cycle_id: @cycle_id)

      ActsAsTenant.with_tenant(@tenant) do
        rating = AssessmentLevelRating.find_by(
          cycle_id: @cycle_id, person_id: @person_id,
          capability_stable_id: cap_sid, level_ordinal: 3
        )
        assert_nil rating.manager_rated_frequency
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

    should "NOT touch participant.started_at on a seeded SelfRated" do
      cap_sid = SecureRandom.uuid_v7
      emit(PersonDevelopment::Events::SelfRated,
        capability_stable_id: cap_sid, level_ordinal: 2, frequency: "consistent",
        cycle_id: @cycle_id, source: "seeded", seeded_from_cycle_id: SecureRandom.uuid_v7)

      ActsAsTenant.with_tenant(@tenant) do
        participant = AssessmentCycleParticipant.find_by(cycle_id: @cycle_id, person_id: @person_id)
        assert_equal "enrolled", participant.status
        assert_nil participant.started_at
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
    should "flip participant status to aligning and stamp the started_by_id" do
      manager = ActsAsTenant.with_tenant(@tenant) { create(:person, tenant: @tenant, name: "Mgr") }

      emit(PersonDevelopment::Events::AlignmentStarted,
        cycle_id: @cycle_id, started_by_id: manager.id)

      ActsAsTenant.with_tenant(@tenant) do
        participant = AssessmentCycleParticipant.find_by(cycle_id: @cycle_id, person_id: @person_id)
        assert_equal "aligning", participant.status
        assert_not_nil participant.alignment_started_at
        assert_equal manager.id, participant.alignment_started_by_id
      end
    end
  end

  context "FullAlignmentCompleted" do
    should "flip participant status to aligned and stamp completed_by_id" do
      manager = ActsAsTenant.with_tenant(@tenant) { create(:person, tenant: @tenant, name: "Mgr") }

      emit(PersonDevelopment::Events::FullAlignmentCompleted,
        cycle_id: @cycle_id, completed_by_id: manager.id)

      ActsAsTenant.with_tenant(@tenant) do
        participant = AssessmentCycleParticipant.find_by(cycle_id: @cycle_id, person_id: @person_id)
        assert_equal "aligned", participant.status
        assert_not_nil participant.aligned_at
        assert_equal manager.id, participant.aligned_by_id
      end
    end
  end

  context "AssessmentAligned" do
    should "set aligned_frequency on the row without changing participant status" do
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

        # Status changes are now driven by AlignmentStarted (PR 1) and
        # FullAlignmentCompleted (PR 3) — AssessmentAligned no longer
        # touches participant lifecycle status.
        participant = AssessmentCycleParticipant.find_by(cycle_id: @cycle_id, person_id: @person_id)
        assert_not_equal "aligned", participant.status
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
end
