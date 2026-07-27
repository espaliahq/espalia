# frozen_string_literal: true

# Record a free-text minute on a live calibration session
# (Operations::CalibrationSessions::RecordNote) — the session-log feed on
# the session page.
class CalibrationSessions::NotesController < ApplicationController
  # POST /calibration_sessions/:calibration_session_id/notes
  def create
    session_record = CalibrationSession.find(params.expect(:calibration_session_id))
    authorize session_record, :flag_expectation?, policy_class: CalibrationSessionPolicy

    Operations::CalibrationSessions::RecordNote.call(
      context: pundit_user,
      params: {
        session_id: session_record.id,
        body: params.expect(:body),
        capability_stable_id: params[:capability_stable_id].presence,
        person_id: params[:person_id].presence
      }
    )

    redirect_to calibration_session_path(session_record, anchor: "session-log"), notice: "Note recorded."
  rescue Operations::Base::ParameterError, RuntimeError => e
    redirect_to calibration_session_path(session_record, anchor: "session-log"), alert: e.message
  rescue ActiveRecord::RecordNotFound
    redirect_to calibration_sessions_path
  end
end
