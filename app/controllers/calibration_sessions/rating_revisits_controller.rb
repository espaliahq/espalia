# frozen_string_literal: true

# Ask a rater to revisit a manager rating from a calibration drill-in's
# person card (Operations::CalibrationSessions::RequestRatingRevisit).
class CalibrationSessions::RatingRevisitsController < ApplicationController
  # POST /calibration_sessions/:calibration_session_id/rating_revisits
  def create
    session_record = CalibrationSession.find(params.expect(:calibration_session_id))
    authorize session_record, :flag_expectation?, policy_class: CalibrationSessionPolicy

    Operations::CalibrationSessions::RequestRatingRevisit.call(
      context: pundit_user,
      params: {
        session_id: session_record.id,
        person_id: params.expect(:person_id),
        capability_stable_id: params.expect(:capability_stable_id),
        level_ordinal: params.expect(:level_ordinal).to_i,
        note: params.expect(:note)
      }
    )

    redirect_to drill_in_path(session_record),
                notice: "Revisit requested — it will appear in the rater's assessment activity."
  rescue Operations::Base::ParameterError, RuntimeError => e
    redirect_to drill_in_path(session_record), alert: e.message
  rescue ActiveRecord::RecordNotFound
    redirect_to calibration_sessions_path
  end

  private

  # Back to the drill-in with the person card still open (the reveal sticks).
  def drill_in_path(session_record)
    calibration_session_capability_path(
      session_record, params[:capability_stable_id], person: params[:person_id]
    )
  end
end
