# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/projection_replay"

class AssessmentCycles::Projections::CurrentStateTest < ActiveSupport::TestCase
  include ProjectionReplayHelpers

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
        enrollment = AssessmentCycleEnrollment.find_by(cycle_id: @cycle_id, person_id: person_id)
        assert_not_nil enrollment
        assert_equal "enrolled", enrollment.status
        assert_not_nil enrollment.enrolled_at
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

    should "mark the enrollment as withdrawn" do
      emit(AssessmentCycles::Events::PersonUnenrolled,
        cycle_id: @cycle_id, person_id: @person_id, framework_id: @framework_id,
        reason: "withdrew", unenrolled_by: nil)

      ActsAsTenant.with_tenant(@tenant) do
        enrollment = AssessmentCycleEnrollment.find_by(cycle_id: @cycle_id, person_id: @person_id)
        assert_equal "withdrawn", enrollment.status
        assert_equal "withdrew", enrollment.withdrawal_reason
        assert_not_nil enrollment.withdrawn_at
      end
    end
  end

  context "re-enrollment after unenroll" do
    setup do
      emit(AssessmentCycles::Events::CycleDefined,
        cycle_id: @cycle_id, framework_id: @framework_id, framework_version: 1,
        name: "Q1", cycle_type: "regular", defined_by: nil)
      @person_id = SecureRandom.uuid_v7
      emit(AssessmentCycles::Events::PersonEnrolled,
        cycle_id: @cycle_id, person_id: @person_id, framework_id: @framework_id,
        framework_version: 1, enrolled_by: nil)
      emit(AssessmentCycles::Events::PersonUnenrolled,
        cycle_id: @cycle_id, person_id: @person_id, framework_id: @framework_id,
        reason: "accidental", unenrolled_by: nil)
    end

    should "reset the existing enrollment row to enrolled state on re-enroll" do
      assert_nothing_raised do
        emit(AssessmentCycles::Events::PersonEnrolled,
          cycle_id: @cycle_id, person_id: @person_id, framework_id: @framework_id,
          framework_version: 1, enrolled_by: nil)
      end

      ActsAsTenant.with_tenant(@tenant) do
        rows = AssessmentCycleEnrollment.where(cycle_id: @cycle_id, person_id: @person_id)
        assert_equal 1, rows.count, "expected a single current-state row, not a duplicate"

        enrollment = rows.first
        assert_equal "enrolled", enrollment.status
        assert_nil enrollment.withdrawn_at
        assert_nil enrollment.withdrawal_reason
        assert_not_nil enrollment.enrolled_at
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
          enrollment = AssessmentCycleEnrollment.find_by(cycle_id: @cycle_id, person_id: pid)
          assert_equal "withdrawn", enrollment.status
          assert_equal "cycle_closed", enrollment.withdrawal_reason
        end
      end
    end
  end

  context "rebuild contract" do
    should "reset! + replay produces identical read-model state" do
      p1, p2 = SecureRandom.uuid_v7, SecureRandom.uuid_v7

      append_and_project(AssessmentCycles::Events::CycleDefined,
        cycle_id: @cycle_id, framework_id: @framework_id, framework_version: 1,
        name: "Q1", cycle_type: "regular", defined_by: nil)
      append_and_project(AssessmentCycles::Events::PersonEnrolled,
        cycle_id: @cycle_id, person_id: p1, framework_id: @framework_id,
        framework_version: 1, enrolled_by: nil)
      append_and_project(AssessmentCycles::Events::PersonEnrolled,
        cycle_id: @cycle_id, person_id: p2, framework_id: @framework_id,
        framework_version: 1, enrolled_by: nil)
      append_and_project(AssessmentCycles::Events::PersonUnenrolled,
        cycle_id: @cycle_id, person_id: p1, reason: "left team")

      before_snapshot = snapshot_read_models(AssessmentCycles::Projections::CurrentState, @tenant)
      assert_equal 1, before_snapshot[:cycles].size
      assert_equal 2, before_snapshot[:enrollments].size

      AssessmentCycles::Projections::CurrentState.reset!(tenant: @tenant)
      ActsAsTenant.with_tenant(@tenant) do
        assert_equal 0, AssessmentCycle.count
        assert_equal 0, AssessmentCycleEnrollment.count
      end

      Projections::Replayer.replay(
        projection_class: AssessmentCycles::Projections::CurrentState,
        tenant: @tenant
      )

      after_snapshot = snapshot_read_models(AssessmentCycles::Projections::CurrentState, @tenant)
      assert_equal before_snapshot, after_snapshot
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

  # Appends an event to the real store AND calls the projection directly.
  # Uses `append` rather than `publish` so subscribers (especially sync
  # handlers that dispatch domain commands) don't fire and create
  # cascading state we didn't ask for. The projection-under-test still
  # sees the event live via the direct call. Replay later reads the
  # appended events back via `event_store.read.of_type(...)`.
  def append_and_project(event_class, **data)
    event = event_class.new(data: data, metadata: { tenant_id: @tenant.id })
    stream = EventStreamNaming.assessment_cycle_stream(@cycle_id, tenant: @tenant)
    Rails.configuration.event_store.append(event, stream_name: stream)
    @projection.call(event)
  end
end
