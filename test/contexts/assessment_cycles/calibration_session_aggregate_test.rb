# frozen_string_literal: true

require "test_helper"

class AssessmentCycles::CalibrationSessionAggregateTest < ActiveSupport::TestCase
  setup do
    @aggregate = AssessmentCycles::CalibrationSessionAggregate.new
    @session_id = SecureRandom.uuid_v7
    @cycle_id = SecureRandom.uuid_v7
    @framework_id = SecureRandom.uuid_v7
    @facilitator_id = SecureRandom.uuid_v7
    @em_1 = SecureRandom.uuid_v7
    @em_2 = SecureRandom.uuid_v7
    @report_1 = SecureRandom.uuid_v7
    @report_2 = SecureRandom.uuid_v7
  end

  def define_session(participant_ids: [ @em_1, @em_2 ], calibrant_person_ids: [ @report_1, @report_2 ])
    @aggregate.define(@session_id, @cycle_id, @framework_id, "Engineering calibration", 2,
                      facilitator_id: @facilitator_id,
                      participant_ids: participant_ids,
                      calibrant_person_ids: calibrant_person_ids,
                      defined_by: @facilitator_id)
  end

  context "#define" do
    should "apply CalibrationSessionDefined with the full snapshot" do
      define_session

      events = @aggregate.unpublished_events.to_a
      assert_equal 1, events.length
      event = events.first
      assert_kind_of AssessmentCycles::Events::CalibrationSessionDefined, event
      assert_equal @session_id, event.data[:session_id]
      assert_equal @cycle_id, event.data[:cycle_id]
      assert_equal @framework_id, event.data[:framework_id]
      assert_equal 2, event.data[:framework_version]
      assert_equal "Engineering calibration", event.data[:name]
      assert_equal @facilitator_id, event.data[:facilitator_id]
      assert_equal [ @em_1, @em_2 ], event.data[:participant_ids]
      assert_equal [ @report_1, @report_2 ], event.data[:calibrant_person_ids]
      assert_equal @facilitator_id, event.data[:defined_by]
    end

    should "raise if already defined" do
      define_session
      err = assert_raises(RuntimeError) { define_session }
      assert_match(/already defined/, err.message)
    end

    should "raise for blank name" do
      err = assert_raises(RuntimeError) do
        @aggregate.define(@session_id, @cycle_id, @framework_id, "  ", 1, facilitator_id: @facilitator_id)
      end
      assert_match(/Name can't be blank/, err.message)
    end

    should "raise for missing facilitator" do
      err = assert_raises(RuntimeError) do
        @aggregate.define(@session_id, @cycle_id, @framework_id, "Eng", 1, facilitator_id: nil)
      end
      assert_match(/Facilitator is required/, err.message)
    end

    should "raise for missing cycle" do
      err = assert_raises(RuntimeError) do
        @aggregate.define(@session_id, nil, @framework_id, "Eng", 1, facilitator_id: @facilitator_id)
      end
      assert_match(/Cycle is required/, err.message)
    end

    should "raise when seeded calibrants include a participant" do
      err = assert_raises(RuntimeError) do
        define_session(calibrant_person_ids: [ @report_1, @em_1 ])
      end
      assert_match(/can't include session raters/, err.message)
    end

    should "raise when seeded calibrants include the facilitator" do
      err = assert_raises(RuntimeError) do
        define_session(calibrant_person_ids: [ @facilitator_id ])
      end
      assert_match(/can't include session raters/, err.message)
    end

    should "dedupe participants and calibrants" do
      define_session(participant_ids: [ @em_1, @em_1 ], calibrant_person_ids: [ @report_1, @report_1 ])

      event = @aggregate.unpublished_events.to_a.first
      assert_equal [ @em_1 ], event.data[:participant_ids]
      assert_equal [ @report_1 ], event.data[:calibrant_person_ids]
    end
  end

  context "draft population curation" do
    setup { define_session }

    should "add a calibrant" do
      new_person = SecureRandom.uuid_v7
      @aggregate.add_calibrant(new_person, added_by: @facilitator_id)

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of AssessmentCycles::Events::CalibrationCalibrantAdded, event
      assert_equal new_person, event.data[:person_id]
      assert_equal @facilitator_id, event.data[:added_by]
    end

    should "raise when adding an existing calibrant" do
      err = assert_raises(RuntimeError) { @aggregate.add_calibrant(@report_1) }
      assert_match(/Already a calibrant/, err.message)
    end

    should "raise when adding a participant as calibrant" do
      err = assert_raises(RuntimeError) { @aggregate.add_calibrant(@em_1) }
      assert_match(/raters can't be calibrated in their own session/, err.message)
    end

    should "raise when adding the facilitator as calibrant" do
      err = assert_raises(RuntimeError) { @aggregate.add_calibrant(@facilitator_id) }
      assert_match(/raters can't be calibrated in their own session/, err.message)
    end

    should "remove a calibrant with reason manual" do
      @aggregate.remove_calibrant(@report_1, removed_by: @facilitator_id)

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of AssessmentCycles::Events::CalibrationCalibrantRemoved, event
      assert_equal @report_1, event.data[:person_id]
      assert_equal "manual", event.data[:reason]
    end

    should "raise when removing a non-calibrant" do
      err = assert_raises(RuntimeError) { @aggregate.remove_calibrant(SecureRandom.uuid_v7) }
      assert_match(/Not a calibrant/, err.message)
    end

    should "allow re-adding a removed calibrant" do
      @aggregate.remove_calibrant(@report_1)
      @aggregate.add_calibrant(@report_1)

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of AssessmentCycles::Events::CalibrationCalibrantAdded, event
    end
  end

  context "draft participant curation" do
    setup { define_session }

    should "add a participant" do
      new_em = SecureRandom.uuid_v7
      @aggregate.add_participant(new_em, added_by: @facilitator_id)

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of AssessmentCycles::Events::CalibrationParticipantAdded, event
      assert_equal new_em, event.data[:participant_id]
    end

    should "auto-remove a current calibrant when promoted to participant" do
      @aggregate.add_participant(@report_1, added_by: @facilitator_id)

      events = @aggregate.unpublished_events.to_a.last(2)
      assert_kind_of AssessmentCycles::Events::CalibrationCalibrantRemoved, events.first
      assert_equal @report_1, events.first.data[:person_id]
      assert_equal "became_participant", events.first.data[:reason]
      assert_kind_of AssessmentCycles::Events::CalibrationParticipantAdded, events.last
      assert_equal @report_1, events.last.data[:participant_id]

      # And the invariant holds — they can't be re-added as calibrant now
      err = assert_raises(RuntimeError) { @aggregate.add_calibrant(@report_1) }
      assert_match(/raters can't be calibrated/, err.message)
    end

    should "raise when adding an existing participant" do
      err = assert_raises(RuntimeError) { @aggregate.add_participant(@em_1) }
      assert_match(/Already a participant/, err.message)
    end

    should "remove a participant without touching the population" do
      @aggregate.remove_participant(@em_1, removed_by: @facilitator_id)

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of AssessmentCycles::Events::CalibrationParticipantRemoved, event
      assert_equal @em_1, event.data[:participant_id]

      # A removed participant may become a calibrant (their own manager's session)
      @aggregate.add_calibrant(@em_1)
      assert_kind_of AssessmentCycles::Events::CalibrationCalibrantAdded,
                     @aggregate.unpublished_events.to_a.last
    end

    should "raise when removing a non-participant" do
      err = assert_raises(RuntimeError) { @aggregate.remove_participant(SecureRandom.uuid_v7) }
      assert_match(/Not a participant/, err.message)
    end
  end

  context "#start" do
    should "freeze participants and calibrants as event-carried snapshots" do
      define_session
      @aggregate.start(started_by_id: @facilitator_id)

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of AssessmentCycles::Events::CalibrationSessionStarted, event
      assert_equal [ @em_1, @em_2 ].sort, event.data[:participant_ids].sort
      assert_equal [ @report_1, @report_2 ].sort, event.data[:calibrant_person_ids].sort
      assert_equal @facilitator_id, event.data[:started_by_id]
    end

    should "raise without participants" do
      define_session(participant_ids: [])
      err = assert_raises(RuntimeError) { @aggregate.start }
      assert_match(/at least one participant/, err.message)
    end

    should "raise without calibrants" do
      define_session(calibrant_person_ids: [])
      err = assert_raises(RuntimeError) { @aggregate.start }
      assert_match(/at least one calibrant/, err.message)
    end

    should "raise when not defined" do
      err = assert_raises(RuntimeError) { @aggregate.start }
      assert_match(/not defined/, err.message)
    end

    should "freeze curation after start" do
      define_session
      @aggregate.start

      [
        -> { @aggregate.add_participant(SecureRandom.uuid_v7) },
        -> { @aggregate.remove_participant(@em_1) },
        -> { @aggregate.add_calibrant(SecureRandom.uuid_v7) },
        -> { @aggregate.remove_calibrant(@report_1) }
      ].each do |mutation|
        err = assert_raises(RuntimeError, &mutation)
        assert_match(/already started/, err.message)
      end
    end

    should "raise when starting twice" do
      define_session
      @aggregate.start
      err = assert_raises(RuntimeError) { @aggregate.start }
      assert_match(/already started/, err.message)
    end
  end

  context "#close" do
    should "close a started session" do
      define_session
      @aggregate.start
      @aggregate.close(closed_by_id: @facilitator_id)

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of AssessmentCycles::Events::CalibrationSessionClosed, event
      assert_equal "facilitator", event.data[:reason]
      assert_equal @facilitator_id, event.data[:closed_by_id]
    end

    should "close a draft session (discard)" do
      define_session
      @aggregate.close

      assert_kind_of AssessmentCycles::Events::CalibrationSessionClosed,
                     @aggregate.unpublished_events.to_a.last
    end

    should "accept the cycle_closed reason" do
      define_session
      @aggregate.close(reason: "cycle_closed")

      assert_equal "cycle_closed", @aggregate.unpublished_events.to_a.last.data[:reason]
    end

    should "no-op when already closed (sync retry safety)" do
      define_session
      @aggregate.close
      count = @aggregate.unpublished_events.to_a.length

      @aggregate.close(reason: "cycle_closed")
      assert_equal count, @aggregate.unpublished_events.to_a.length
    end

    should "raise for an invalid reason" do
      define_session
      err = assert_raises(RuntimeError) { @aggregate.close(reason: "bored") }
      assert_match(/Invalid close reason/, err.message)
    end

    should "raise when not defined" do
      err = assert_raises(RuntimeError) { @aggregate.close }
      assert_match(/not defined/, err.message)
    end

    should "freeze curation after close" do
      define_session
      @aggregate.close

      err = assert_raises(RuntimeError) { @aggregate.add_calibrant(SecureRandom.uuid_v7) }
      assert_match(/closed/, err.message)
    end
  end
end
