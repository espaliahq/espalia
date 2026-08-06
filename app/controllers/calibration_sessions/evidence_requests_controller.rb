# frozen_string_literal: true

# Fire a cell-scoped evidence request from a calibration drill-in's person
# card (Operations::CalibrationSessions::RequestEvidence) — §f: when the
# room can't answer "what did you see?", the resolution IS a request.
class CalibrationSessions::EvidenceRequestsController < ApplicationController
  include CalibrationSessions::DrillInReturnPath

  # POST /calibration_sessions/:calibration_session_id/evidence_requests
  def create
    session_record = CalibrationSession.find(params.expect(:calibration_session_id))
    authorize session_record, :flag_expectation?, policy_class: CalibrationSessionPolicy

    Operations::CalibrationSessions::RequestEvidence.call(
      context: pundit_user,
      params: {
        session_id: session_record.id,
        person_id: params.expect(:person_id),
        requestee_person_id: params.expect(:requestee_person_id),
        capability_stable_id: params.expect(:capability_stable_id),
        level_ordinal: params.expect(:level_ordinal).to_i,
        message: params[:message].presence
      }
    )

    # `activity=open` so the ask lands somewhere visible even if the room
    # had the log panel closed — the rule every outcome follows. Only on
    # success: a failed request records nothing for the panel to show.
    redirect_to drill_in_return_path(session_record, person_id: params[:person_id],
                                     extra: { activity: "open" }),
                notice: "Feedback / evidence requested — it lands on their hub with a notification."
  rescue Operations::Base::ParameterError, RuntimeError => e
    redirect_to drill_in_return_path(session_record, person_id: params[:person_id]), alert: e.message
  rescue Pundit::NotAuthorizedError
    redirect_to drill_in_return_path(session_record, person_id: params[:person_id]),
                alert: "You don't have access to this person's assessment, so you can't request feedback about them."
  rescue ActiveRecord::RecordNotFound
    redirect_to calibration_sessions_path
  end
end
