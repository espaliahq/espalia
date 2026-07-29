# frozen_string_literal: true

# Record a free-text minute on a live calibration session
# (Operations::CalibrationSessions::RecordNote) — the session-log side
# panel, which rides both the session page and the capability drill-in.
class CalibrationSessions::NotesController < ApplicationController
  include CalibrationSessions::DrillInReturnPath

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
        # On the drill-in the opened person card IS the note's subject, and
        # the pane carries them as `person`.
        person_id: (params[:person_id].presence || params[:person].presence)
      }
    )

    redirect_to return_path(session_record), notice: "Note recorded."
  rescue Operations::Base::ParameterError, RuntimeError => e
    redirect_to return_path(session_record), alert: e.message
  rescue ActiveRecord::RecordNotFound
    redirect_to calibration_sessions_path
  end

  private

  # A note recorded from the drill-in returns to the drill-in with its
  # working state intact — being yanked back to the session page mid-
  # discussion is exactly what the side panel exists to avoid. `activity=open`
  # rides along either way so the new entry lands somewhere visible even if
  # the room had the panel closed.
  def return_path(session_record)
    if params[:from] == "drill_in" && params[:capability_stable_id].present?
      drill_in_return_path(session_record, person_id: params[:person].presence,
                                           extra: { activity: "open" })
    else
      calibration_session_path(session_record, anchor: "session-log", activity: "open")
    end
  end
end
