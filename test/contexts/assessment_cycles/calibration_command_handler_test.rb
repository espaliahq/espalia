# frozen_string_literal: true

require "test_helper"

class AssessmentCycles::CalibrationCommandHandlerTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @handler = AssessmentCycles::CalibrationCommandHandler.new
    @session_id = SecureRandom.uuid_v7
    @cycle_id = SecureRandom.uuid_v7
    @framework_id = SecureRandom.uuid_v7
    @facilitator_id = SecureRandom.uuid_v7
    @em = SecureRandom.uuid_v7
    @report = SecureRandom.uuid_v7
  end

  teardown do
    ActsAsTenant.current_tenant = nil
  end

  context "session lifecycle" do
    should "publish events to the session's own stream with tenant metadata" do
      @handler.define_session(@session_id, @cycle_id, @framework_id, "Eng calibration", 1,
                              facilitator_id: @facilitator_id,
                              participant_ids: [ @em ],
                              calibrant_person_ids: [ @report ])
      @handler.start_session(@session_id, started_by_id: @facilitator_id)
      @handler.close_session(@session_id, closed_by_id: @facilitator_id)

      stream = EventStreamNaming.calibration_session_stream(@session_id)
      events = Rails.configuration.event_store.read.stream(stream).to_a
      assert_equal 3, events.length
      assert_kind_of AssessmentCycles::Events::CalibrationSessionDefined, events[0]
      assert_kind_of AssessmentCycles::Events::CalibrationSessionStarted, events[1]
      assert_kind_of AssessmentCycles::Events::CalibrationSessionClosed, events[2]
      events.each { |event| assert_equal @tenant.id, event.metadata[:tenant_id] }
    end

    should "not touch the assessment cycle's stream" do
      @handler.define_session(@session_id, @cycle_id, @framework_id, "Eng calibration", 1,
                              facilitator_id: @facilitator_id,
                              participant_ids: [ @em ],
                              calibrant_person_ids: [ @report ])

      cycle_stream = EventStreamNaming.assessment_cycle_stream(@cycle_id)
      assert_empty Rails.configuration.event_store.read.stream(cycle_stream).to_a
    end

    should "serialize population curation through the aggregate invariants" do
      @handler.define_session(@session_id, @cycle_id, @framework_id, "Eng calibration", 1,
                              facilitator_id: @facilitator_id,
                              participant_ids: [ @em ],
                              calibrant_person_ids: [ @report ])

      err = assert_raises(RuntimeError) { @handler.add_calibrant(@session_id, @em) }
      assert_match(/raters can't be calibrated/, err.message)

      new_person = SecureRandom.uuid_v7
      @handler.add_calibrant(@session_id, new_person, added_by: @facilitator_id)
      @handler.remove_calibrant(@session_id, @report, removed_by: @facilitator_id)

      stream = EventStreamNaming.calibration_session_stream(@session_id)
      events = Rails.configuration.event_store.read.stream(stream).to_a
      assert_kind_of AssessmentCycles::Events::CalibrationCalibrantAdded, events[1]
      assert_kind_of AssessmentCycles::Events::CalibrationCalibrantRemoved, events[2]
    end

    should "no-op on double close" do
      @handler.define_session(@session_id, @cycle_id, @framework_id, "Eng calibration", 1,
                              facilitator_id: @facilitator_id,
                              participant_ids: [ @em ],
                              calibrant_person_ids: [ @report ])
      @handler.close_session(@session_id)
      @handler.close_session(@session_id, reason: "cycle_closed")

      stream = EventStreamNaming.calibration_session_stream(@session_id)
      closed = Rails.configuration.event_store.read.stream(stream).to_a
        .select { |e| e.is_a?(AssessmentCycles::Events::CalibrationSessionClosed) }
      assert_equal 1, closed.length
    end
  end
end
