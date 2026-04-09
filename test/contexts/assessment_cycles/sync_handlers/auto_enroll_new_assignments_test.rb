# frozen_string_literal: true

require "test_helper"

class AssessmentCycles::SyncHandlers::AutoEnrollNewAssignmentsTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @handler = AssessmentCycles::SyncHandlers::AutoEnrollNewAssignments.new
    @cycle_handler = AssessmentCycles::CommandHandler.new
    @pd_handler = PersonDevelopment::CommandHandler.new

    @framework_id = SecureRandom.uuid_v7
    @person_id = SecureRandom.uuid_v7

    # Assign the person to the framework so the PersonDev aggregate exists
    # and join_cycle's ensure_assigned! guard passes.
    Rails.configuration.event_store.with_metadata(tenant_id: @tenant.id) do
      @pd_handler.assign_to_framework(
        @person_id, @framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7
      )
    end
  end

  teardown do
    ActsAsTenant.current_tenant = nil
  end

  # Build a fake PersonAssignedToFramework event carrying the tenant in metadata.
  def build_event
    PersonDevelopment::Events::PersonAssignedToFramework.new(
      data: {
        person_id: @person_id,
        framework_id: @framework_id,
        role_id: SecureRandom.uuid_v7,
        level_id: SecureRandom.uuid_v7
      },
      metadata: { tenant_id: @tenant.id }
    )
  end

  def define_open_cycle
    cycle_id = SecureRandom.uuid_v7
    Rails.configuration.event_store.with_metadata(tenant_id: @tenant.id) do
      @cycle_handler.define_cycle(cycle_id, @framework_id, "Q1 2026", "regular", 1)
    end
    cycle_id
  end

  context "when an open cycle exists for the framework" do
    setup do
      @cycle_id = define_open_cycle
    end

    should "enroll the person and emit JoinedAssessmentCycle on the PersonDev stream" do
      @handler.call(build_event)

      participant = AssessmentCycleParticipant.find_by(
        cycle_id: @cycle_id, person_id: @person_id
      )
      assert_not_nil participant
      assert_equal "enrolled", participant.status

      stream = EventStreamNaming.person_development_stream(@person_id, @framework_id)
      events = Rails.configuration.event_store.read.stream(stream).to_a
      joined = events.find { |e| e.is_a?(PersonDevelopment::Events::JoinedAssessmentCycle) }
      assert_not_nil joined
      assert_equal @cycle_id, joined.data[:cycle_id]
    end

    should "be idempotent when the participant is already enrolled" do
      @handler.call(build_event)
      # Calling a second time must not raise and must not create a duplicate
      # participant row.
      assert_nothing_raised { @handler.call(build_event) }

      rows = AssessmentCycleParticipant.where(cycle_id: @cycle_id, person_id: @person_id)
      assert_equal 1, rows.count
    end
  end

  context "when no open cycle exists for the framework" do
    should "silently no-op without raising or creating a participant" do
      assert_nothing_raised { @handler.call(build_event) }

      assert_equal 0, AssessmentCycleParticipant.for_person(@person_id).count
    end
  end

  context "when only a closed cycle exists for the framework" do
    setup do
      @closed_cycle_id = define_open_cycle
      Rails.configuration.event_store.with_metadata(tenant_id: @tenant.id) do
        @cycle_handler.close_cycle(@closed_cycle_id)
      end
    end

    should "not enroll the person in the closed cycle" do
      @handler.call(build_event)

      # The participant row (if any) from the closed cycle must be withdrawn,
      # and no new active participant row should appear.
      assert_equal 0,
        AssessmentCycleParticipant.for_person(@person_id).active.count
    end
  end

  context "guard against accidental re-registration as a projection" do
    should "not be in AssessmentCycles::Projections::CurrentState.handled_events" do
      refute_includes AssessmentCycles::Projections::CurrentState.handled_events,
        PersonDevelopment::Events::PersonAssignedToFramework
    end
  end
end
