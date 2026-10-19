# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/projection_replay"

class AssessmentCycles::Projections::CalibrationSessionsTest < ActiveSupport::TestCase
  include ProjectionReplayHelpers

  setup do
    @tenant = create(:tenant)
    @projection = AssessmentCycles::Projections::CalibrationSessions.new
    @session_id = SecureRandom.uuid_v7
    @cycle_id = SecureRandom.uuid_v7
    @framework_id = SecureRandom.uuid_v7
    @facilitator_id = SecureRandom.uuid_v7
    @em_1 = SecureRandom.uuid_v7
    @em_2 = SecureRandom.uuid_v7
    @report_1 = SecureRandom.uuid_v7
    @report_2 = SecureRandom.uuid_v7
  end

  def emit_defined(**overrides)
    emit(AssessmentCycles::Events::CalibrationSessionDefined, **{
      session_id: @session_id,
      cycle_id: @cycle_id,
      framework_id: @framework_id,
      framework_version: 2,
      name: "Engineering calibration",
      facilitator_id: @facilitator_id,
      participant_ids: [ @em_1, @em_2 ],
      calibrant_person_ids: [ @report_1, @report_2 ],
      defined_by: @facilitator_id
    }.merge(overrides))
  end

  context "CalibrationSessionDefined" do
    should "create the session row with the event-carried id as PK" do
      emit_defined

      ActsAsTenant.with_tenant(@tenant) do
        session = CalibrationSession.find_by(id: @session_id)
        assert_not_nil session
        assert_equal @cycle_id, session.cycle_id
        assert_equal @framework_id, session.framework_id
        assert_equal 2, session.framework_version
        assert_equal "Engineering calibration", session.name
        assert_equal @facilitator_id, session.facilitator_id
        assert_equal "draft", session.status
        assert_equal @facilitator_id, session.defined_by
      end
    end

    should "seed participant and calibrant membership rows" do
      emit_defined

      ActsAsTenant.with_tenant(@tenant) do
        session = CalibrationSession.find(@session_id)
        assert_equal [ @em_1, @em_2 ].sort, session.participants.pluck(:person_id).sort
        assert_equal [ @report_1, @report_2 ].sort, session.calibrants.pluck(:person_id).sort
      end
    end
  end

  context "membership curation" do
    setup { emit_defined }

    should "add a calibrant" do
      new_person = SecureRandom.uuid_v7
      emit(AssessmentCycles::Events::CalibrationCalibrantAdded,
        session_id: @session_id, person_id: new_person, added_by: @facilitator_id)

      ActsAsTenant.with_tenant(@tenant) do
        member = CalibrationSessionMember.find_by(session_id: @session_id, person_id: new_person)
        assert_equal "calibrant", member.member_type
        assert_equal @facilitator_id, member.added_by
      end
    end

    should "remove a calibrant" do
      emit(AssessmentCycles::Events::CalibrationCalibrantRemoved,
        session_id: @session_id, person_id: @report_1, reason: "manual", removed_by: @facilitator_id)

      ActsAsTenant.with_tenant(@tenant) do
        assert_nil CalibrationSessionMember.find_by(session_id: @session_id, person_id: @report_1)
        assert_equal 1, CalibrationSession.find(@session_id).calibrants.count
      end
    end

    should "promote a calibrant to participant across the removal + add pair" do
      emit(AssessmentCycles::Events::CalibrationCalibrantRemoved,
        session_id: @session_id, person_id: @report_1, reason: "became_participant", removed_by: @facilitator_id)
      emit(AssessmentCycles::Events::CalibrationParticipantAdded,
        session_id: @session_id, participant_id: @report_1, added_by: @facilitator_id)

      ActsAsTenant.with_tenant(@tenant) do
        member = CalibrationSessionMember.find_by(session_id: @session_id, person_id: @report_1)
        assert_equal "participant", member.member_type
        assert_equal 1, CalibrationSessionMember.where(session_id: @session_id, person_id: @report_1).count
      end
    end

    should "remove a participant" do
      emit(AssessmentCycles::Events::CalibrationParticipantRemoved,
        session_id: @session_id, participant_id: @em_1, removed_by: @facilitator_id)

      ActsAsTenant.with_tenant(@tenant) do
        assert_equal [ @em_2 ], CalibrationSession.find(@session_id).participants.pluck(:person_id)
      end
    end
  end

  context "CalibrationSessionStarted" do
    setup { emit_defined }

    should "flip the session to started with attribution" do
      emit(AssessmentCycles::Events::CalibrationSessionStarted,
        session_id: @session_id,
        participant_ids: [ @em_1, @em_2 ],
        calibrant_person_ids: [ @report_1, @report_2 ],
        started_by_id: @facilitator_id)

      ActsAsTenant.with_tenant(@tenant) do
        session = CalibrationSession.find(@session_id)
        assert_equal "started", session.status
        assert_equal @facilitator_id, session.started_by_id
        assert_not_nil session.started_at
      end
    end
  end

  context "CalibrationSessionClosed" do
    setup { emit_defined }

    should "flip the session to closed with reason" do
      emit(AssessmentCycles::Events::CalibrationSessionClosed,
        session_id: @session_id, reason: "cycle_closed", closed_by_id: nil)

      ActsAsTenant.with_tenant(@tenant) do
        session = CalibrationSession.find(@session_id)
        assert_equal "closed", session.status
        assert_equal "cycle_closed", session.close_reason
        assert_nil session.closed_by_id
        assert_not_nil session.closed_at
      end
    end
  end

  context "archive, restore and rename" do
    setup do
      emit_defined
      emit(AssessmentCycles::Events::CalibrationSessionClosed,
        session_id: @session_id, reason: "facilitator", closed_by_id: @facilitator_id)
    end

    should "stamp archived_at and archived_by_id, and clear both on restore" do
      emit(AssessmentCycles::Events::CalibrationSessionArchived,
        session_id: @session_id, archived_by_id: @facilitator_id)

      ActsAsTenant.with_tenant(@tenant) do
        session = CalibrationSession.find(@session_id)
        assert session.archived?
        assert_not_nil session.archived_at
        assert_equal @facilitator_id, session.archived_by_id
        assert_equal [ session ], CalibrationSession.archived.to_a
        assert_empty CalibrationSession.unarchived
      end

      emit(AssessmentCycles::Events::CalibrationSessionUnarchived,
        session_id: @session_id, unarchived_by_id: @facilitator_id)

      ActsAsTenant.with_tenant(@tenant) do
        session = CalibrationSession.find(@session_id)
        assert_not session.archived?
        assert_nil session.archived_by_id
        assert_equal "closed", session.status
      end
    end

    should "update the name" do
      emit(AssessmentCycles::Events::CalibrationSessionRenamed,
        session_id: @session_id, name: "Engineering · H2 2026",
        previous_name: "Engineering calibration", renamed_by_id: @facilitator_id)

      ActsAsTenant.with_tenant(@tenant) do
        assert_equal "Engineering · H2 2026", CalibrationSession.find(@session_id).name
      end
    end
  end

  context "rebuild contract" do
    should "reset! + replay produces identical read-model state including the stable PK" do
      new_person = SecureRandom.uuid_v7

      append_and_project(AssessmentCycles::Events::CalibrationSessionDefined,
        session_id: @session_id, cycle_id: @cycle_id, framework_id: @framework_id,
        framework_version: 2, name: "Engineering calibration",
        facilitator_id: @facilitator_id,
        participant_ids: [ @em_1 ], calibrant_person_ids: [ @report_1, @report_2 ],
        defined_by: @facilitator_id)
      append_and_project(AssessmentCycles::Events::CalibrationCalibrantAdded,
        session_id: @session_id, person_id: new_person, added_by: @facilitator_id)
      append_and_project(AssessmentCycles::Events::CalibrationCalibrantRemoved,
        session_id: @session_id, person_id: @report_2, reason: "manual", removed_by: @facilitator_id)
      append_and_project(AssessmentCycles::Events::CalibrationSessionStarted,
        session_id: @session_id, participant_ids: [ @em_1 ],
        calibrant_person_ids: [ @report_1, new_person ], started_by_id: @facilitator_id)
      append_and_project(AssessmentCycles::Events::CalibrationSessionClosed,
        session_id: @session_id, reason: "facilitator", closed_by_id: @facilitator_id)
      append_and_project(AssessmentCycles::Events::CalibrationSessionRenamed,
        session_id: @session_id, name: "Engineering · H1", previous_name: "Engineering calibration",
        renamed_by_id: @facilitator_id)
      append_and_project(AssessmentCycles::Events::CalibrationSessionArchived,
        session_id: @session_id, archived_by_id: @facilitator_id)
      append_and_project(AssessmentCycles::Events::CalibrationSessionUnarchived,
        session_id: @session_id, unarchived_by_id: @facilitator_id)
      append_and_project(AssessmentCycles::Events::CalibrationSessionArchived,
        session_id: @session_id, archived_by_id: @em_1)

      before_snapshot = snapshot_read_models(AssessmentCycles::Projections::CalibrationSessions, @tenant)
      assert_equal 1, before_snapshot[:sessions].size
      assert_equal 3, before_snapshot[:members].size
      assert_equal "Engineering · H1", before_snapshot[:sessions].first["name"]
      assert_equal @em_1, before_snapshot[:sessions].first["archived_by_id"]

      AssessmentCycles::Projections::CalibrationSessions.reset!(tenant: @tenant)
      ActsAsTenant.with_tenant(@tenant) do
        assert_equal 0, CalibrationSession.count
        assert_equal 0, CalibrationSessionMember.count
      end

      Projections::Replayer.replay(
        projection_class: AssessmentCycles::Projections::CalibrationSessions,
        tenant: @tenant
      )

      after_snapshot = snapshot_read_models(AssessmentCycles::Projections::CalibrationSessions, @tenant)
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

  # Appends an event to the real store AND calls the projection directly
  # (see current_state_test.rb for why append, not publish).
  def append_and_project(event_class, **data)
    event = event_class.new(data: data, metadata: { tenant_id: @tenant.id })
    stream = EventStreamNaming.calibration_session_stream(@session_id, tenant: @tenant)
    Rails.configuration.event_store.append(event, stream_name: stream)
    @projection.call(event)
  end
end
