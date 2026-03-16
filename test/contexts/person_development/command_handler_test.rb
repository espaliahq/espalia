# frozen_string_literal: true

require "test_helper"

class PersonDevelopment::CommandHandlerTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @handler = PersonDevelopment::CommandHandler.new

    @person_id = SecureRandom.uuid_v7
    @framework_id = SecureRandom.uuid_v7
    @role_id = SecureRandom.uuid_v7
    @level_id = SecureRandom.uuid_v7
  end

  teardown do
    ActsAsTenant.current_tenant = nil
  end

  context "full assessment cycle" do
    should "support assign, open cycle, rate, revise, complete" do
      # Assign person to framework
      @handler.assign_to_framework(@person_id, @framework_id, @role_id, @level_id)

      # Open assessment cycle
      cycle_id = SecureRandom.uuid_v7
      @handler.open_assessment_cycle(@person_id, @framework_id, cycle_id, "Q1 2026", "regular", 1)

      # Self-rate a capability
      cap_sid = SecureRandom.uuid_v7
      level_1 = SecureRandom.uuid_v7
      @handler.rate_self(@person_id, @framework_id, cap_sid, level_1, comment: "I'm here")

      # Verify assessment state projection
      state = AssessmentState.find_by(
        person_id: @person_id,
        framework_id: @framework_id,
        capability_stable_id: cap_sid
      )
      assert_not_nil state
      assert_equal level_1, state.self_rated_level_id

      # Revise the rating
      level_2 = SecureRandom.uuid_v7
      @handler.revise_self_rating(@person_id, @framework_id, cap_sid, level_2,
                                  rationale: "Grew since last review")

      state.reload
      assert_equal level_2, state.self_rated_level_id

      # Complete the cycle
      @handler.complete_assessment_cycle(@person_id, @framework_id, cycle_id)

      # Verify stream has all events
      stream = EventStreamNaming.person_development_stream(@person_id, @framework_id)
      events = Rails.configuration.event_store.read.stream(stream).to_a
      assert_equal 5, events.length
      assert_kind_of PersonDevelopment::Events::PersonAssignedToFramework, events[0]
      assert_kind_of PersonDevelopment::Events::AssessmentCycleOpened, events[1]
      assert_kind_of PersonDevelopment::Events::SelfRated, events[2]
      assert_kind_of PersonDevelopment::Events::SelfRatingRevised, events[3]
      assert_kind_of PersonDevelopment::Events::AssessmentCycleCompleted, events[4]
    end
  end
end
