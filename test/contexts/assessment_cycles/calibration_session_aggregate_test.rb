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

  def flag_cell(ordinal: 4, suggestion_id: @suggestion_id)
    @aggregate.flag_expectation(
      capability_stable_id: @cap_stable, level_ordinal: ordinal,
      suggestion_id: suggestion_id, flagged_by_id: @facilitator_id,
      reason: "Read three different ways"
    )
  end

  context "#flag_expectation" do
    setup do
      @cap_stable = SecureRandom.uuid_v7
      @suggestion_id = SecureRandom.uuid_v7
    end

    should "emit CalibrationExpectationFlagged with the clarification's suggestion_id" do
      define_session
      @aggregate.start(started_by_id: @facilitator_id)
      flag_cell

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of AssessmentCycles::Events::CalibrationExpectationFlagged, event
      assert_equal @session_id, event.data[:session_id]
      assert_equal @cap_stable, event.data[:capability_stable_id]
      assert_equal 4, event.data[:level_ordinal]
      assert_equal @suggestion_id, event.data[:suggestion_id]
      assert_equal @facilitator_id, event.data[:flagged_by_id]
      assert_equal "Read three different ways", event.data[:reason]
    end

    should "reject flagging the same cell twice in one session" do
      define_session
      @aggregate.start(started_by_id: @facilitator_id)
      flag_cell
      err = assert_raises(RuntimeError) { flag_cell(suggestion_id: SecureRandom.uuid_v7) }
      assert_match(/already flagged/, err.message)
    end

    should "allow the same capability at a different level" do
      define_session
      @aggregate.start(started_by_id: @facilitator_id)
      flag_cell(ordinal: 3)
      flag_cell(ordinal: 4, suggestion_id: SecureRandom.uuid_v7)
      flagged = @aggregate.unpublished_events.to_a
        .select { |e| e.is_a?(AssessmentCycles::Events::CalibrationExpectationFlagged) }
      assert_equal 2, flagged.size
    end

    should "reject flagging from a draft session" do
      define_session
      err = assert_raises(RuntimeError) { flag_cell }
      assert_match(/hasn't started/, err.message)
    end

    should "reject flagging from a closed session" do
      define_session
      @aggregate.start(started_by_id: @facilitator_id)
      @aggregate.close(closed_by_id: @facilitator_id)
      err = assert_raises(RuntimeError) { flag_cell }
      assert_match(/closed/, err.message)
    end
  end

  def request_revisit(person_id: @report_1, rater_id: @em_1, ordinal: 3, note: "Compare with Sam's L3s")
    @aggregate.request_rating_revisit(
      person_id: person_id, capability_stable_id: @cap_stable, level_ordinal: ordinal,
      rater_id: rater_id, note: note, requested_by_id: @facilitator_id
    )
  end

  context "#request_rating_revisit" do
    setup do
      @cap_stable = SecureRandom.uuid_v7
      define_session
      @aggregate.start(started_by_id: @facilitator_id)
    end

    should "emit CalibrationRatingRevisitRequested with the note (never a target rating)" do
      request_revisit

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of AssessmentCycles::Events::CalibrationRatingRevisitRequested, event
      assert_equal @report_1, event.data[:person_id]
      assert_equal @em_1, event.data[:rater_id]
      assert_equal "Compare with Sam's L3s", event.data[:note]
      assert_equal @facilitator_id, event.data[:requested_by_id]
      assert_not event.data.key?(:suggested_frequency), "value-free by design"
    end

    should "reject a person outside the frozen population" do
      err = assert_raises(RuntimeError) { request_revisit(person_id: SecureRandom.uuid_v7) }
      assert_match(/not in this session's population/, err.message)
    end

    should "reject a rater who is not a participant" do
      err = assert_raises(RuntimeError) { request_revisit(rater_id: SecureRandom.uuid_v7) }
      assert_match(/not a participant/, err.message)
    end

    should "reject a blank note" do
      err = assert_raises(RuntimeError) { request_revisit(note: "  ") }
      assert_match(/note cannot be blank/, err.message)
    end

    should "reject a duplicate ask for the same person and cell" do
      request_revisit
      err = assert_raises(RuntimeError) { request_revisit }
      assert_match(/already requested/, err.message)
    end
  end

  context "#record_note" do
    setup do
      define_session
      @aggregate.start(started_by_id: @facilitator_id)
    end

    should "emit CalibrationNoteRecorded with optional anchors" do
      @aggregate.record_note(body: "Add Priya to the org-wide session",
                             person_id: @report_1, recorded_by_id: @facilitator_id)

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of AssessmentCycles::Events::CalibrationNoteRecorded, event
      assert_equal "Add Priya to the org-wide session", event.data[:body]
      assert_equal @report_1, event.data[:person_id]
      assert_equal @facilitator_id, event.data[:recorded_by_id]
    end

    should "reject a blank body" do
      err = assert_raises(RuntimeError) { @aggregate.record_note(body: " ") }
      assert_match(/blank/, err.message)
    end

    should "reject a person anchor outside the population" do
      err = assert_raises(RuntimeError) do
        @aggregate.record_note(body: "n", person_id: SecureRandom.uuid_v7)
      end
      assert_match(/not in this session's population/, err.message)
    end

    should "reject notes on a draft session" do
      draft = AssessmentCycles::CalibrationSessionAggregate.new
      draft.define(SecureRandom.uuid_v7, @cycle_id, @framework_id, "Draft", 1,
                   facilitator_id: @facilitator_id,
                   participant_ids: [ @em_1 ], calibrant_person_ids: [ @report_1 ])
      err = assert_raises(RuntimeError) { draft.record_note(body: "too early") }
      assert_match(/hasn't started/, err.message)
    end
  end

  context "#archive" do
    setup do
      define_session
      @aggregate.start(started_by_id: @facilitator_id)
    end

    should "archive a closed session" do
      @aggregate.close(closed_by_id: @facilitator_id)
      @aggregate.archive(archived_by_id: @facilitator_id)

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of AssessmentCycles::Events::CalibrationSessionArchived, event
      assert_equal @session_id, event.data[:session_id]
      assert_equal @facilitator_id, event.data[:archived_by_id]
    end

    should "refuse a session that isn't closed" do
      err = assert_raises(RuntimeError) { @aggregate.archive(archived_by_id: @facilitator_id) }
      assert_match(/Only a closed session can be archived/, err.message)
    end

    should "no-op when already archived" do
      @aggregate.close
      @aggregate.archive
      assert_no_difference -> { @aggregate.unpublished_events.to_a.size } do
        @aggregate.archive
      end
    end

    should "raise when not defined" do
      err = assert_raises(RuntimeError) { AssessmentCycles::CalibrationSessionAggregate.new.archive }
      assert_match(/not defined/, err.message)
    end
  end

  context "#unarchive" do
    setup do
      define_session
      @aggregate.close
    end

    should "restore an archived session, which stays closed" do
      @aggregate.archive
      @aggregate.unarchive(unarchived_by_id: @facilitator_id)

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of AssessmentCycles::Events::CalibrationSessionUnarchived, event
      assert_equal @facilitator_id, event.data[:unarchived_by_id]
      # Still closed: archiving again is allowed, curation is not.
      @aggregate.archive
      assert_raises(RuntimeError) { @aggregate.add_calibrant(SecureRandom.uuid_v7) }
    end

    should "no-op when not archived" do
      assert_no_difference -> { @aggregate.unpublished_events.to_a.size } do
        @aggregate.unarchive
      end
    end
  end

  context "#rename" do
    setup { define_session }

    should "emit CalibrationSessionRenamed with the stripped name and the old one" do
      @aggregate.rename("  Engineering · H2  ", renamed_by_id: @facilitator_id)

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of AssessmentCycles::Events::CalibrationSessionRenamed, event
      assert_equal "Engineering · H2", event.data[:name]
      assert_equal "Engineering calibration", event.data[:previous_name]
      assert_equal @facilitator_id, event.data[:renamed_by_id]
    end

    should "refuse a blank name" do
      err = assert_raises(RuntimeError) { @aggregate.rename("   ") }
      assert_match(/Name can't be blank/, err.message)
    end

    should "no-op on an unchanged name, whitespace aside" do
      assert_no_difference -> { @aggregate.unpublished_events.to_a.size } do
        @aggregate.rename(" Engineering calibration ")
      end
    end

    should "chain previous names across renames" do
      @aggregate.rename("First")
      @aggregate.rename("Second")
      assert_equal "First", @aggregate.unpublished_events.to_a.last.data[:previous_name]
    end

    should "be allowed while live, closed and archived" do
      @aggregate.start
      @aggregate.rename("Live name")
      @aggregate.close
      @aggregate.rename("Closed name")
      @aggregate.archive
      @aggregate.rename("Archived name")

      renamed = @aggregate.unpublished_events.to_a
        .grep(AssessmentCycles::Events::CalibrationSessionRenamed)
      assert_equal [ "Live name", "Closed name", "Archived name" ], renamed.map { |e| e.data[:name] }
    end
  end
end
