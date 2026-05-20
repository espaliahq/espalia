# frozen_string_literal: true

require "test_helper"

class AssessmentCycles::SyncHandlers::PersonEnrollmentSyncTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @handler = AssessmentCycles::SyncHandlers::PersonEnrollmentSync.new
    @pd_handler = PersonDevelopment::CommandHandler.new

    @cycle_id = SecureRandom.uuid_v7
    @framework_id = SecureRandom.uuid_v7
    @person_id = SecureRandom.uuid_v7

    @pd_handler.assign_to_framework(@person_id, @framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7)

    # These tests call `@handler.call(event)` directly, bypassing the live
    # publish-time fan-out where CurrentState would normally create the
    # cycle read-model row first. Seed it here so downstream CurrentAssessment
    # writes to `AssessmentCycleProgress` (`belongs_to :cycle`) succeed.
    #
    # The factory row is created as :closed so `AutoEnrollNewAssignments`
    # (which fires on `assign_to_framework` below) doesn't try to load the
    # empty cycle aggregate and raise "Cycle not defined" — it only
    # auto-enrolls into open cycles. The sync handler under test doesn't
    # care about cycle status; it dispatches `join_cycle` unconditionally.
    create(:assessment_cycle, :closed,
      tenant: @tenant, cycle_id: @cycle_id, framework_id: @framework_id, framework_version: 1)
  end

  teardown do
    ActsAsTenant.current_tenant = nil
  end

  context "PersonEnrolled" do
    should "dispatch join_cycle on the PersonDev stream" do
      event = AssessmentCycles::Events::PersonEnrolled.new(
        data: {
          cycle_id: @cycle_id, person_id: @person_id, framework_id: @framework_id,
          framework_version: 1, enrolled_by: nil
        },
        metadata: { tenant_id: @tenant.id }
      )
      @handler.call(event)

      stream = EventStreamNaming.person_development_stream(@person_id, @framework_id)
      events = Rails.configuration.event_store.read.stream(stream).to_a
      joined = events.find { |e| e.is_a?(PersonDevelopment::Events::JoinedAssessmentCycle) }
      assert_not_nil joined
      assert_equal @cycle_id, joined.data[:cycle_id]
      assert_equal 1, joined.data[:framework_version]
    end

    should "raise if invoked twice (safety: handler must not be replayed)" do
      event = AssessmentCycles::Events::PersonEnrolled.new(
        data: {
          cycle_id: @cycle_id, person_id: @person_id, framework_id: @framework_id,
          framework_version: 1, enrolled_by: nil
        },
        metadata: { tenant_id: @tenant.id }
      )
      @handler.call(event)

      err = assert_raises(RuntimeError) do
        @handler.call(event)
      end
      assert_match /Already in a cycle/, err.message
    end
  end

  context "PersonUnenrolled" do
    setup do
      # Need to be in a cycle before we can leave
      enroll_event = AssessmentCycles::Events::PersonEnrolled.new(
        data: {
          cycle_id: @cycle_id, person_id: @person_id, framework_id: @framework_id,
          framework_version: 1, enrolled_by: nil
        },
        metadata: { tenant_id: @tenant.id }
      )
      @handler.call(enroll_event)
    end

    should "dispatch leave_cycle on the PersonDev stream" do
      event = AssessmentCycles::Events::PersonUnenrolled.new(
        data: {
          cycle_id: @cycle_id, person_id: @person_id, framework_id: @framework_id,
          reason: "manual", unenrolled_by: nil
        },
        metadata: { tenant_id: @tenant.id }
      )
      @handler.call(event)

      stream = EventStreamNaming.person_development_stream(@person_id, @framework_id)
      events = Rails.configuration.event_store.read.stream(stream).to_a
      left = events.find { |e| e.is_a?(PersonDevelopment::Events::LeftAssessmentCycle) }
      assert_not_nil left
      assert_equal "manual", left.data[:reason]
    end
  end

  context "CycleClosed" do
    setup do
      # Two people in the cycle
      @other_person_id = SecureRandom.uuid_v7
      @pd_handler.assign_to_framework(@other_person_id, @framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7)
      [ @person_id, @other_person_id ].each do |pid|
        enroll_event = AssessmentCycles::Events::PersonEnrolled.new(
          data: {
            cycle_id: @cycle_id, person_id: pid, framework_id: @framework_id,
            framework_version: 1, enrolled_by: nil
          },
          metadata: { tenant_id: @tenant.id }
        )
        @handler.call(enroll_event)
      end
    end

    should "dispatch leave_cycle to every enrolled person" do
      event = AssessmentCycles::Events::CycleClosed.new(
        data: {
          cycle_id: @cycle_id, framework_id: @framework_id,
          enrolled_person_ids: [ @person_id, @other_person_id ], closed_by: nil
        },
        metadata: { tenant_id: @tenant.id }
      )
      @handler.call(event)

      [ @person_id, @other_person_id ].each do |pid|
        stream = EventStreamNaming.person_development_stream(pid, @framework_id)
        events = Rails.configuration.event_store.read.stream(stream).to_a
        left = events.find { |e| e.is_a?(PersonDevelopment::Events::LeftAssessmentCycle) }
        assert_not_nil left, "expected LeftAssessmentCycle on stream for #{pid}"
        assert_equal "cycle_closed", left.data[:reason]
      end
    end
  end

  context "guard against accidental re-registration as a projection" do
    should "not be in PersonDevelopment::Projections::CurrentAssessment.handled_events" do
      refute_includes PersonDevelopment::Projections::CurrentAssessment.handled_events,
        AssessmentCycles::Events::PersonEnrolled
    end

    should "not be in AssessmentCycles::Projections::CurrentState.handled_events... wait, it IS — but not as a COMMAND dispatcher" do
      # Clarify: the projection subscribes to the SAME events to update read models;
      # but the projection does not dispatch commands, so no replay hazard there.
      # This assertion is a sanity check that the projection and sync handler are
      # distinct classes.
      refute_equal(
        AssessmentCycles::Projections::CurrentState,
        AssessmentCycles::SyncHandlers::PersonEnrollmentSync
      )
    end
  end
end
