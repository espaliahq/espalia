# frozen_string_literal: true

require "test_helper"

class AssessmentCycles::CommandHandlerTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @handler = AssessmentCycles::CommandHandler.new
    @cycle_id = SecureRandom.uuid_v7
    @framework_id = SecureRandom.uuid_v7
    @person_id = SecureRandom.uuid_v7

    # Assign the person to a framework so join_cycle propagation can succeed
    @pd_handler = PersonDevelopment::CommandHandler.new
    @pd_handler.assign_to_framework(@person_id, @framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7)
  end

  teardown do
    ActsAsTenant.current_tenant = nil
  end

  context "define_cycle + enroll + close" do
    should "publish events to the cycle stream and propagate to the person stream" do
      @handler.define_cycle(@cycle_id, @framework_id, "Q1 2026", "regular", 1)
      @handler.enroll(@cycle_id, @person_id)

      # Cycle stream contains Defined + Enrolled
      cycle_stream = EventStreamNaming.assessment_cycle_stream(@cycle_id)
      cycle_events = Rails.configuration.event_store.read.stream(cycle_stream).to_a
      assert_equal 2, cycle_events.length
      assert_kind_of AssessmentCycles::Events::CycleDefined, cycle_events[0]
      assert_kind_of AssessmentCycles::Events::PersonEnrolled, cycle_events[1]

      # Person stream contains Assigned + Joined (via the sync handler)
      person_stream = EventStreamNaming.person_development_stream(@person_id, @framework_id)
      person_events = Rails.configuration.event_store.read.stream(person_stream).to_a
      joined = person_events.find { |e| e.is_a?(PersonDevelopment::Events::JoinedAssessmentCycle) }
      assert_not_nil joined
      assert_equal @cycle_id, joined.data[:cycle_id]
      assert_equal 1, joined.data[:framework_version]
    end

    should "materialise the cycle read model" do
      @handler.define_cycle(@cycle_id, @framework_id, "Q1 2026", "regular", 1, defined_by: @person_id)
      @handler.enroll(@cycle_id, @person_id, enrolled_by: @person_id)

      cycle = AssessmentCycle.find_by(cycle_id: @cycle_id)
      assert_not_nil cycle
      assert_equal "open", cycle.status
      assert_equal "Q1 2026", cycle.name
      assert_equal 1, cycle.framework_version
      assert_equal 1, cycle.enrollments.count
      assert_equal "enrolled", cycle.enrollments.first.status
    end

    should "propagate close event as conclude_cycle on each person stream" do
      @handler.define_cycle(@cycle_id, @framework_id, "Q1 2026", "regular", 1)
      @handler.enroll(@cycle_id, @person_id)
      @handler.close_cycle(@cycle_id)

      person_stream = EventStreamNaming.person_development_stream(@person_id, @framework_id)
      person_events = Rails.configuration.event_store.read.stream(person_stream).to_a
      concluded = person_events.find { |e| e.is_a?(PersonDevelopment::Events::AssessmentCycleConcluded) }
      assert_not_nil concluded
      assert_equal @cycle_id, concluded.data[:cycle_id]
    end

    should "conclude participants when the cycle closes" do
      @handler.define_cycle(@cycle_id, @framework_id, "Q1 2026", "regular", 1)
      @handler.enroll(@cycle_id, @person_id)
      @handler.close_cycle(@cycle_id)

      cycle = AssessmentCycle.find_by(cycle_id: @cycle_id)
      assert_equal "closed", cycle.status
      participant = cycle.enrollments.find_by(person_id: @person_id)
      assert_equal "concluded", participant.status
      assert_not_nil participant.concluded_at
      assert_nil participant.withdrawal_reason
    end
  end

  context "unenroll" do
    should "mark the participant as withdrawn and leave the PersonDev cycle" do
      @handler.define_cycle(@cycle_id, @framework_id, "Q1 2026", "regular", 1)
      @handler.enroll(@cycle_id, @person_id)
      @handler.unenroll(@cycle_id, @person_id, "manual")

      cycle = AssessmentCycle.find_by(cycle_id: @cycle_id)
      participant = cycle.enrollments.find_by(person_id: @person_id)
      assert_equal "withdrawn", participant.status
      assert_equal "manual", participant.withdrawal_reason

      person_stream = EventStreamNaming.person_development_stream(@person_id, @framework_id)
      person_events = Rails.configuration.event_store.read.stream(person_stream).to_a
      assert(person_events.any? { |e| e.is_a?(PersonDevelopment::Events::LeftAssessmentCycle) })
    end
  end

  context "edit commands" do
    setup do
      @handler.define_cycle(@cycle_id, @framework_id, "Q1 2026", "regular", 1)
    end

    should "rename the cycle and materialise the new name" do
      @handler.rename_cycle(@cycle_id, "Q1 2026 Review")
      assert_equal "Q1 2026 Review", AssessmentCycle.find_by(cycle_id: @cycle_id).name
    end

    should "change the cycle type" do
      @handler.change_cycle_type(@cycle_id, "promotion_review")
      assert_equal "promotion_review", AssessmentCycle.find_by(cycle_id: @cycle_id).cycle_type
    end

    should "set and clear the planned end date" do
      @handler.set_cycle_planned_end(@cycle_id, "2026-06-30")
      assert_equal Date.new(2026, 6, 30), AssessmentCycle.find_by(cycle_id: @cycle_id).planned_end_at

      @handler.set_cycle_planned_end(@cycle_id, nil)
      assert_nil AssessmentCycle.find_by(cycle_id: @cycle_id).planned_end_at
    end

    should "persist planned_end_at when defining a cycle" do
      other = SecureRandom.uuid_v7
      other_fw = SecureRandom.uuid_v7
      @handler.define_cycle(other, other_fw, "Q3", "regular", 1, planned_end_at: "2026-12-01")
      assert_equal Date.new(2026, 12, 1), AssessmentCycle.find_by(cycle_id: other).planned_end_at
    end
  end

  context "partial unique constraint" do
    should "reject a second open cycle for the same framework" do
      @handler.define_cycle(@cycle_id, @framework_id, "Q1 2026", "regular", 1)

      other_cycle_id = SecureRandom.uuid_v7
      assert_raises(ActiveRecord::RecordNotUnique) do
        @handler.define_cycle(other_cycle_id, @framework_id, "Q1 2026 Alt", "regular", 1)
      end
    end

    should "allow a new cycle once the previous is closed" do
      @handler.define_cycle(@cycle_id, @framework_id, "Q1 2026", "regular", 1)
      @handler.close_cycle(@cycle_id)

      other_cycle_id = SecureRandom.uuid_v7
      @handler.define_cycle(other_cycle_id, @framework_id, "Q2 2026", "regular", 1)
      assert AssessmentCycle.find_by(cycle_id: other_cycle_id).open?
    end
  end
end
