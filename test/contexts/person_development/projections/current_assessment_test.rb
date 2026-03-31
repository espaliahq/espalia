# frozen_string_literal: true

require "test_helper"

class PersonDevelopment::Projections::CurrentAssessmentTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @projection = PersonDevelopment::Projections::CurrentAssessment.new
    @person_id = SecureRandom.uuid_v7
    @framework_id = SecureRandom.uuid_v7
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
        assert_equal "none", assignment.cycle_status
      end
    end
  end

  context "AssessmentCycleOpened" do
    should "update assignment cycle_status to open" do
      role_id = SecureRandom.uuid_v7
      level_id = SecureRandom.uuid_v7
      cycle_id = SecureRandom.uuid_v7

      emit(PersonDevelopment::Events::PersonAssignedToFramework,
        person_id: @person_id, framework_id: @framework_id,
        role_id: role_id, level_id: level_id)
      emit(PersonDevelopment::Events::AssessmentCycleOpened,
        cycle_id: cycle_id, cycle_name: "Q1 2026", cycle_type: "regular",
        framework_version: 1)

      ActsAsTenant.with_tenant(@tenant) do
        assignment = PersonFrameworkAssignment.find_by(
          person_id: @person_id, framework_id: @framework_id
        )
        assert_equal "open", assignment.cycle_status
        assert_equal cycle_id, assignment.current_cycle_id
        assert_equal "Q1 2026", assignment.cycle_name
      end
    end
  end

  context "AssessmentCycleCompleted" do
    should "update assignment cycle_status to completed" do
      role_id = SecureRandom.uuid_v7
      level_id = SecureRandom.uuid_v7
      cycle_id = SecureRandom.uuid_v7

      emit(PersonDevelopment::Events::PersonAssignedToFramework,
        person_id: @person_id, framework_id: @framework_id,
        role_id: role_id, level_id: level_id)
      emit(PersonDevelopment::Events::AssessmentCycleOpened,
        cycle_id: cycle_id, cycle_name: "Q1 2026", cycle_type: "regular",
        framework_version: 1)
      emit(PersonDevelopment::Events::AssessmentCycleCompleted,
        cycle_id: cycle_id)

      ActsAsTenant.with_tenant(@tenant) do
        assignment = PersonFrameworkAssignment.find_by(
          person_id: @person_id, framework_id: @framework_id
        )
        assert_equal "completed", assignment.cycle_status
      end
    end
  end

  context "SelfRated" do
    should "create an AssessmentLevelRating row" do
      cap_sid = SecureRandom.uuid_v7

      emit(PersonDevelopment::Events::SelfRated,
        capability_stable_id: cap_sid, level_ordinal: 3, frequency: "consistent", comment: "Good")

      ActsAsTenant.with_tenant(@tenant) do
        rating = AssessmentLevelRating.find_by(
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

    should "create separate rows for different level_ordinals" do
      cap_sid = SecureRandom.uuid_v7

      emit(PersonDevelopment::Events::SelfRated,
        capability_stable_id: cap_sid, level_ordinal: 2, frequency: "some", comment: nil)
      emit(PersonDevelopment::Events::SelfRated,
        capability_stable_id: cap_sid, level_ordinal: 3, frequency: "consistent", comment: nil)

      ActsAsTenant.with_tenant(@tenant) do
        assert_equal 2, AssessmentLevelRating.where(person_id: @person_id,
          capability_stable_id: cap_sid).count
      end
    end

    should "handle multiple capabilities independently" do
      cap1 = SecureRandom.uuid_v7
      cap2 = SecureRandom.uuid_v7

      emit(PersonDevelopment::Events::SelfRated,
        capability_stable_id: cap1, level_ordinal: 3, frequency: "some", comment: nil)
      emit(PersonDevelopment::Events::SelfRated,
        capability_stable_id: cap2, level_ordinal: 3, frequency: "occasional", comment: nil)

      ActsAsTenant.with_tenant(@tenant) do
        assert_equal 2, AssessmentLevelRating.where(person_id: @person_id).count
        r1 = AssessmentLevelRating.find_by(capability_stable_id: cap1)
        r2 = AssessmentLevelRating.find_by(capability_stable_id: cap2)
        assert_equal "some", r1.self_rated_frequency
        assert_equal "occasional", r2.self_rated_frequency
      end
    end
  end

  context "SelfRatingRevised" do
    should "update the existing AssessmentLevelRating row" do
      cap_sid = SecureRandom.uuid_v7

      emit(PersonDevelopment::Events::SelfRated,
        capability_stable_id: cap_sid, level_ordinal: 3, frequency: "some", comment: nil)
      emit(PersonDevelopment::Events::SelfRatingRevised,
        capability_stable_id: cap_sid, level_ordinal: 3, frequency: "consistent",
        comment: "Reconsidered", rationale: "Growth")

      ActsAsTenant.with_tenant(@tenant) do
        rating = AssessmentLevelRating.find_by(
          person_id: @person_id, capability_stable_id: cap_sid, level_ordinal: 3
        )
        assert_equal "consistent", rating.self_rated_frequency
        assert_equal 1, AssessmentLevelRating.where(person_id: @person_id,
          capability_stable_id: cap_sid).count
      end
    end
  end

  context "ManagerRated" do
    should "set manager_rated_frequency on the row" do
      cap_sid = SecureRandom.uuid_v7

      emit(PersonDevelopment::Events::ManagerRated,
        capability_stable_id: cap_sid, level_ordinal: 3, frequency: "occasional", comment: "Room to grow")

      ActsAsTenant.with_tenant(@tenant) do
        rating = AssessmentLevelRating.find_by(
          person_id: @person_id, capability_stable_id: cap_sid, level_ordinal: 3
        )
        assert_not_nil rating
        assert_equal "occasional", rating.manager_rated_frequency
        assert_equal "Room to grow", rating.manager_rated_comment
        assert_not_nil rating.last_manager_rated_at
      end
    end
  end

  context "ManagerRatingRevised" do
    should "update manager_rated_frequency on existing row" do
      cap_sid = SecureRandom.uuid_v7

      emit(PersonDevelopment::Events::ManagerRated,
        capability_stable_id: cap_sid, level_ordinal: 3, frequency: "some", comment: "Initial")
      emit(PersonDevelopment::Events::ManagerRatingRevised,
        capability_stable_id: cap_sid, level_ordinal: 3, frequency: "consistent",
        comment: "Reconsidered", rationale: "Saw improvement")

      ActsAsTenant.with_tenant(@tenant) do
        rating = AssessmentLevelRating.find_by(
          person_id: @person_id, capability_stable_id: cap_sid, level_ordinal: 3
        )
        assert_equal "consistent", rating.manager_rated_frequency
        assert_equal "Reconsidered", rating.manager_rated_comment
        assert_not_nil rating.last_manager_rated_at
        # Only one row — revised, not duplicated
        assert_equal 1, AssessmentLevelRating.where(
          person_id: @person_id, capability_stable_id: cap_sid
        ).count
      end
    end

    should "not overwrite self_rated_frequency" do
      cap_sid = SecureRandom.uuid_v7

      emit(PersonDevelopment::Events::SelfRated,
        capability_stable_id: cap_sid, level_ordinal: 3, frequency: "some", comment: nil)
      emit(PersonDevelopment::Events::ManagerRated,
        capability_stable_id: cap_sid, level_ordinal: 3, frequency: "occasional", comment: nil)
      emit(PersonDevelopment::Events::ManagerRatingRevised,
        capability_stable_id: cap_sid, level_ordinal: 3, frequency: "consistent",
        comment: nil, rationale: "Updated")

      ActsAsTenant.with_tenant(@tenant) do
        rating = AssessmentLevelRating.find_by(
          person_id: @person_id, capability_stable_id: cap_sid, level_ordinal: 3
        )
        assert_equal "some", rating.self_rated_frequency
        assert_equal "consistent", rating.manager_rated_frequency
      end
    end
  end

  context "AssessmentAligned" do
    should "set aligned_frequency on the row" do
      cap_sid = SecureRandom.uuid_v7

      emit(PersonDevelopment::Events::AssessmentAligned,
        capability_stable_id: cap_sid, level_ordinal: 3, aligned_frequency: "consistent",
        comment: "Agreed")

      ActsAsTenant.with_tenant(@tenant) do
        rating = AssessmentLevelRating.find_by(
          person_id: @person_id, capability_stable_id: cap_sid, level_ordinal: 3
        )
        assert_not_nil rating
        assert_equal "consistent", rating.aligned_frequency
        assert_equal "Agreed", rating.aligned_comment
        assert_not_nil rating.last_aligned_at
      end
    end

    should "not overwrite an existing self_rated_frequency on the same row" do
      cap_sid = SecureRandom.uuid_v7

      emit(PersonDevelopment::Events::SelfRated,
        capability_stable_id: cap_sid, level_ordinal: 3, frequency: "some", comment: nil)
      emit(PersonDevelopment::Events::AssessmentAligned,
        capability_stable_id: cap_sid, level_ordinal: 3, aligned_frequency: "consistent",
        comment: nil)

      ActsAsTenant.with_tenant(@tenant) do
        rating = AssessmentLevelRating.find_by(
          person_id: @person_id, capability_stable_id: cap_sid, level_ordinal: 3
        )
        assert_equal "some", rating.self_rated_frequency
        assert_equal "consistent", rating.aligned_frequency
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
