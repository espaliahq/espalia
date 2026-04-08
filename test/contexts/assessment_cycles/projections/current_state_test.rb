# frozen_string_literal: true

require "test_helper"

class AssessmentCycles::Projections::CurrentStateTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @projection = AssessmentCycles::Projections::CurrentState.new
    @cycle_id = SecureRandom.uuid_v7
    @framework_id = SecureRandom.uuid_v7
  end

  context "CycleDefined" do
    should "create an AssessmentCycle row in 'open' state" do
      emit(AssessmentCycles::Events::CycleDefined,
        cycle_id: @cycle_id,
        framework_id: @framework_id,
        framework_version: 2,
        name: "Q1 2026 Review",
        cycle_type: "regular",
        defined_by: SecureRandom.uuid_v7)

      ActsAsTenant.with_tenant(@tenant) do
        cycle = AssessmentCycle.find_by(cycle_id: @cycle_id)
        assert_not_nil cycle
        assert_equal "Q1 2026 Review", cycle.name
        assert_equal "open", cycle.status
        assert_equal 2, cycle.framework_version
        assert_not_nil cycle.opened_at
      end
    end
  end

  context "PersonEnrolled" do
    setup do
      emit(AssessmentCycles::Events::CycleDefined,
        cycle_id: @cycle_id, framework_id: @framework_id, framework_version: 1,
        name: "Q1", cycle_type: "regular", defined_by: nil)
    end

    should "create a participant row in 'enrolled' state" do
      person_id = SecureRandom.uuid_v7
      emit(AssessmentCycles::Events::PersonEnrolled,
        cycle_id: @cycle_id, person_id: person_id, framework_id: @framework_id,
        framework_version: 1, enrolled_by: nil)

      ActsAsTenant.with_tenant(@tenant) do
        participant = AssessmentCycleParticipant.find_by(cycle_id: @cycle_id, person_id: person_id)
        assert_not_nil participant
        assert_equal "enrolled", participant.status
        assert_not_nil participant.enrolled_at
      end
    end
  end

  context "PersonUnenrolled" do
    setup do
      emit(AssessmentCycles::Events::CycleDefined,
        cycle_id: @cycle_id, framework_id: @framework_id, framework_version: 1,
        name: "Q1", cycle_type: "regular", defined_by: nil)
      @person_id = SecureRandom.uuid_v7
      emit(AssessmentCycles::Events::PersonEnrolled,
        cycle_id: @cycle_id, person_id: @person_id, framework_id: @framework_id,
        framework_version: 1, enrolled_by: nil)
    end

    should "mark the participant as withdrawn" do
      emit(AssessmentCycles::Events::PersonUnenrolled,
        cycle_id: @cycle_id, person_id: @person_id, framework_id: @framework_id,
        reason: "withdrew", unenrolled_by: nil)

      ActsAsTenant.with_tenant(@tenant) do
        participant = AssessmentCycleParticipant.find_by(cycle_id: @cycle_id, person_id: @person_id)
        assert_equal "withdrawn", participant.status
        assert_equal "withdrew", participant.withdrawal_reason
        assert_not_nil participant.withdrawn_at
      end
    end
  end

  context "CycleClosed" do
    setup do
      emit(AssessmentCycles::Events::CycleDefined,
        cycle_id: @cycle_id, framework_id: @framework_id, framework_version: 1,
        name: "Q1", cycle_type: "regular", defined_by: nil)
      @p1 = SecureRandom.uuid_v7
      @p2 = SecureRandom.uuid_v7
      [ @p1, @p2 ].each do |pid|
        emit(AssessmentCycles::Events::PersonEnrolled,
          cycle_id: @cycle_id, person_id: pid, framework_id: @framework_id,
          framework_version: 1, enrolled_by: nil)
      end
    end

    should "close the cycle and withdraw remaining participants" do
      emit(AssessmentCycles::Events::CycleClosed,
        cycle_id: @cycle_id, framework_id: @framework_id,
        enrolled_person_ids: [ @p1, @p2 ], closed_by: nil)

      ActsAsTenant.with_tenant(@tenant) do
        cycle = AssessmentCycle.find_by(cycle_id: @cycle_id)
        assert_equal "closed", cycle.status
        assert_not_nil cycle.closed_at

        [ @p1, @p2 ].each do |pid|
          participant = AssessmentCycleParticipant.find_by(cycle_id: @cycle_id, person_id: pid)
          assert_equal "withdrawn", participant.status
          assert_equal "cycle_closed", participant.withdrawal_reason
        end
      end
    end
  end

  private

  def emit(event_class, **data)
    event = event_class.new(
      data: data,
      metadata: { tenant_id: @tenant.id }
    )
    @projection.call(event)
  end
end
