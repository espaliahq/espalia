# frozen_string_literal: true

# Add / remove participant raters on a draft calibration session.
# Dispatches through the shared Operations::CalibrationSessions classes.
class CalibrationSessions::ParticipantsController < ApplicationController
  before_action :set_session

  # POST /calibration_sessions/:calibration_session_id/participants
  def create
    authorize @session, :curate?
    Operations::CalibrationSessions::AddParticipant.call(
      context: pundit_user,
      params: { session_id: @session.id, person_id: params.expect(:person_id) }
    )
    redirect_to calibration_session_path(@session), notice: "Participant added."
  rescue Operations::Base::ParameterError, RuntimeError => e
    redirect_to calibration_session_path(@session), alert: e.message
  end

  # DELETE /calibration_sessions/:calibration_session_id/participants/:id
  def destroy
    authorize @session, :curate?
    Operations::CalibrationSessions::RemoveParticipant.call(
      context: pundit_user,
      params: { session_id: @session.id, person_id: params.expect(:id) }
    )
    redirect_to calibration_session_path(@session), status: :see_other, notice: "Participant removed."
  rescue Operations::Base::ParameterError, RuntimeError => e
    redirect_to calibration_session_path(@session), status: :see_other, alert: e.message
  end

  private

  def set_session
    @session = CalibrationSession.find(params.expect(:calibration_session_id))
  rescue ActiveRecord::RecordNotFound
    redirect_to calibration_sessions_path
  end
end
