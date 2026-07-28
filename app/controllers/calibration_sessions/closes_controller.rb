# frozen_string_literal: true

# Closes a calibration session (terminal).
class CalibrationSessions::ClosesController < ApplicationController
  # POST /calibration_sessions/:id/close
  def create
    session_record = CalibrationSession.find(params.expect(:id))
    authorize session_record, :close?

    Operations::CalibrationSessions::Close.call(
      context: pundit_user, params: { session_id: session_record.id }
    )
    redirect_to calibration_session_path(session_record), notice: "Session closed."
  rescue ActiveRecord::RecordNotFound
    redirect_to calibration_sessions_path
  rescue Operations::Base::ParameterError, RuntimeError => e
    redirect_to calibration_session_path(params[:id]), alert: e.message
  end
end
