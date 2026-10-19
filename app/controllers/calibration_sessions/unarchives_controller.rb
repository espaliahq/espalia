# frozen_string_literal: true

# Restores an archived calibration session to the default list. It stays
# closed.
class CalibrationSessions::UnarchivesController < ApplicationController
  # POST /calibration_sessions/:id/unarchive
  def create
    session_record = CalibrationSession.find(params.expect(:id))
    authorize session_record, :unarchive?

    Operations::CalibrationSessions::Unarchive.call(
      context: pundit_user, params: { session_id: session_record.id }
    )
    redirect_back_or_to calibration_sessions_path, notice: "“#{session_record.name}” restored."
  rescue ActiveRecord::RecordNotFound
    redirect_to calibration_sessions_path
  rescue Operations::Base::ParameterError, RuntimeError => e
    redirect_back_or_to calibration_sessions_path, alert: e.message
  end
end
