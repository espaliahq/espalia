# frozen_string_literal: true

require "test_helper"

class PersonDevelopment::Projections::CurrentAssessmentTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @projection = PersonDevelopment::Projections::CurrentAssessment.new
    @person_id = SecureRandom.uuid_v7
    @framework_id = SecureRandom.uuid_v7
  end

  context "SelfRated" do
    should "create an AssessmentState record" do
      cap_sid = SecureRandom.uuid_v7
      level_id = SecureRandom.uuid_v7

      emit(PersonDevelopment::Events::SelfRated,
        capability_stable_id: cap_sid, level_id: level_id, comment: "Good")

      ActsAsTenant.with_tenant(@tenant) do
        state = AssessmentState.find_by(
          person_id: @person_id,
          framework_id: @framework_id,
          capability_stable_id: cap_sid
        )
        assert_not_nil state
        assert_equal level_id, state.self_rated_level_id
        assert_not_nil state.last_self_rated_at
      end
    end

    should "handle multiple capabilities independently" do
      cap1 = SecureRandom.uuid_v7
      cap2 = SecureRandom.uuid_v7
      level1 = SecureRandom.uuid_v7
      level2 = SecureRandom.uuid_v7

      emit(PersonDevelopment::Events::SelfRated,
        capability_stable_id: cap1, level_id: level1, comment: nil)
      emit(PersonDevelopment::Events::SelfRated,
        capability_stable_id: cap2, level_id: level2, comment: nil)

      ActsAsTenant.with_tenant(@tenant) do
        assert_equal 2, AssessmentState.where(person_id: @person_id).count

        s1 = AssessmentState.find_by(capability_stable_id: cap1)
        s2 = AssessmentState.find_by(capability_stable_id: cap2)
        assert_equal level1, s1.self_rated_level_id
        assert_equal level2, s2.self_rated_level_id
      end
    end
  end

  context "SelfRatingRevised" do
    should "update the existing AssessmentState" do
      cap_sid = SecureRandom.uuid_v7
      original_level = SecureRandom.uuid_v7
      revised_level = SecureRandom.uuid_v7

      emit(PersonDevelopment::Events::SelfRated,
        capability_stable_id: cap_sid, level_id: original_level, comment: nil)

      emit(PersonDevelopment::Events::SelfRatingRevised,
        capability_stable_id: cap_sid, new_level_id: revised_level,
        comment: "Reconsidered", rationale: "Growth")

      ActsAsTenant.with_tenant(@tenant) do
        state = AssessmentState.find_by(
          person_id: @person_id,
          framework_id: @framework_id,
          capability_stable_id: cap_sid
        )
        assert_equal revised_level, state.self_rated_level_id
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
