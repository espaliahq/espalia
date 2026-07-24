# frozen_string_literal: true

require "test_helper"

class AssessmentCycles::SyncHandlers::CalibrationSessionCloseSyncTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @cycle_handler = AssessmentCycles::CommandHandler.new
    @calibration_handler = AssessmentCycles::CalibrationCommandHandler.new
    @cycle_id = SecureRandom.uuid_v7
    @framework_id = SecureRandom.uuid_v7
    @facilitator_id = SecureRandom.uuid_v7

    @cycle_handler.define_cycle(@cycle_id, @framework_id, "Q3 2026", "regular", 1)
  end

  teardown do
    ActsAsTenant.current_tenant = nil
  end

  def define_session(session_id, cycle_id: @cycle_id, framework_id: @framework_id)
    @calibration_handler.define_session(
      session_id, cycle_id, framework_id, "Calibration #{session_id[0, 4]}", 1,
      facilitator_id: @facilitator_id,
      participant_ids: [ SecureRandom.uuid_v7 ],
      calibrant_person_ids: [ SecureRandom.uuid_v7 ]
    )
  end

  context "on CycleClosed" do
    should "close the cycle's draft and started sessions with reason cycle_closed" do
      draft_session = SecureRandom.uuid_v7
      live_session = SecureRandom.uuid_v7
      define_session(draft_session)
      define_session(live_session)
      @calibration_handler.start_session(live_session, started_by_id: @facilitator_id)

      @cycle_handler.close_cycle(@cycle_id)

      [ draft_session, live_session ].each do |session_id|
        session = CalibrationSession.find(session_id)
        assert_equal "closed", session.status
        assert_equal "cycle_closed", session.close_reason
        assert_nil session.closed_by_id
      end
    end

    should "leave an already-closed session's original close intact" do
      session_id = SecureRandom.uuid_v7
      define_session(session_id)
      @calibration_handler.close_session(session_id, closed_by_id: @facilitator_id)

      @cycle_handler.close_cycle(@cycle_id)

      session = CalibrationSession.find(session_id)
      assert_equal "facilitator", session.close_reason
      assert_equal @facilitator_id, session.closed_by_id

      stream = EventStreamNaming.calibration_session_stream(session_id)
      closed_events = Rails.configuration.event_store.read.stream(stream).to_a
        .select { |e| e.is_a?(AssessmentCycles::Events::CalibrationSessionClosed) }
      assert_equal 1, closed_events.length
    end

    should "not touch sessions belonging to other cycles" do
      other_cycle_id = SecureRandom.uuid_v7
      other_framework_id = SecureRandom.uuid_v7
      @cycle_handler.define_cycle(other_cycle_id, other_framework_id, "Q4 2026", "regular", 1)
      other_session = SecureRandom.uuid_v7
      define_session(other_session, cycle_id: other_cycle_id, framework_id: other_framework_id)

      @cycle_handler.close_cycle(@cycle_id)

      assert_equal "draft", CalibrationSession.find(other_session).status
    end
  end
end
