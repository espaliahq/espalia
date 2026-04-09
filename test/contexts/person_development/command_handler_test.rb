# frozen_string_literal: true

require "test_helper"

class PersonDevelopment::CommandHandlerTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @handler = PersonDevelopment::CommandHandler.new
    @cycle_handler = AssessmentCycles::CommandHandler.new

    @person_id = SecureRandom.uuid_v7
    @framework_id = SecureRandom.uuid_v7
    @role_id = SecureRandom.uuid_v7
    @level_id = SecureRandom.uuid_v7
  end

  teardown do
    ActsAsTenant.current_tenant = nil
  end

  context "full assessment cycle via cycle handler + rating handler" do
    should "support define+enroll, rate, revise, leave" do
      # Assign person to framework
      @handler.assign_to_framework(@person_id, @framework_id, @role_id, @level_id)

      # Define and enroll in a cycle — the sync handler propagates to the person stream
      cycle_id = SecureRandom.uuid_v7
      @cycle_handler.define_cycle(cycle_id, @framework_id, "Q1 2026", "regular", 1)
      @cycle_handler.enroll(cycle_id, @person_id)

      # Self-rate a capability at level 3
      cap_sid = SecureRandom.uuid_v7
      @handler.rate_self(@person_id, @framework_id, cap_sid,
        level_ordinal: 3, frequency: "consistent", cycle_id: cycle_id, comment: "I'm here")

      # Verify assessment level rating projection
      rating = AssessmentLevelRating.find_by(
        cycle_id: cycle_id,
        person_id: @person_id,
        framework_id: @framework_id,
        capability_stable_id: cap_sid,
        level_ordinal: 3
      )
      assert_not_nil rating
      assert_equal "consistent", rating.self_rated_frequency
      assert_equal cycle_id, rating.cycle_id

      # Revise the rating
      @handler.revise_self_rating(@person_id, @framework_id, cap_sid,
        level_ordinal: 3, frequency: "occasional", rationale: "On reflection", cycle_id: cycle_id)

      rating.reload
      assert_equal "occasional", rating.self_rated_frequency

      # Leave the cycle (emulating cycle close)
      @cycle_handler.close_cycle(cycle_id)

      # Verify the PersonDev stream contains the expected events
      stream = EventStreamNaming.person_development_stream(@person_id, @framework_id)
      events = Rails.configuration.event_store.read.stream(stream).to_a
      assert_equal 5, events.length
      assert_kind_of PersonDevelopment::Events::PersonAssignedToFramework, events[0]
      assert_kind_of PersonDevelopment::Events::JoinedAssessmentCycle, events[1]
      assert_kind_of PersonDevelopment::Events::SelfRated, events[2]
      assert_kind_of PersonDevelopment::Events::SelfRatingRevised, events[3]
      assert_kind_of PersonDevelopment::Events::LeftAssessmentCycle, events[4]
    end
  end

  context "manager rating flow" do
    should "support rate_as_manager, revise_manager_rating, and align_assessment" do
      @handler.assign_to_framework(@person_id, @framework_id, @role_id, @level_id)

      cycle_id = SecureRandom.uuid_v7
      @cycle_handler.define_cycle(cycle_id, @framework_id, "Q1 2026", "regular", 1)
      @cycle_handler.enroll(cycle_id, @person_id)

      cap_sid = SecureRandom.uuid_v7

      # Manager rates
      @handler.rate_as_manager(@person_id, @framework_id, cap_sid,
        level_ordinal: 3, frequency: "some", cycle_id: cycle_id, comment: "Room to grow")

      rating = AssessmentLevelRating.find_by(
        cycle_id: cycle_id,
        person_id: @person_id,
        framework_id: @framework_id,
        capability_stable_id: cap_sid,
        level_ordinal: 3
      )
      assert_not_nil rating
      assert_equal "some", rating.manager_rated_frequency
      assert_equal "Room to grow", rating.manager_rated_comment

      # Manager revises
      @handler.revise_manager_rating(@person_id, @framework_id, cap_sid,
        level_ordinal: 3, frequency: "occasional", rationale: "Saw improvement", cycle_id: cycle_id)

      rating.reload
      assert_equal "occasional", rating.manager_rated_frequency

      # Alignment
      @handler.align_assessment(@person_id, @framework_id, cap_sid,
        level_ordinal: 3, aligned_frequency: "occasional", cycle_id: cycle_id,
        comment: "Agreed on occasional")

      rating.reload
      assert_equal "occasional", rating.aligned_frequency
      assert_equal "Agreed on occasional", rating.aligned_comment

      # Verify stream
      stream = EventStreamNaming.person_development_stream(@person_id, @framework_id)
      events = Rails.configuration.event_store.read.stream(stream).to_a
      rating_events = events.select do |e|
        e.is_a?(PersonDevelopment::Events::ManagerRated) ||
          e.is_a?(PersonDevelopment::Events::ManagerRatingRevised) ||
          e.is_a?(PersonDevelopment::Events::AssessmentAligned)
      end
      assert_equal 3, rating_events.length
    end
  end
end
