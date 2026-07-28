# frozen_string_literal: true

# Add / remove participant raters on a draft calibration session.
# Dispatches through the shared Operations::CalibrationSessions classes.
class CalibrationSessions::ParticipantsController < ApplicationController
  before_action :set_session

  # POST /calibration_sessions/:calibration_session_id/participants
  #
  # Accepts the person picker's multi-select (`person_ids[]`) or a single
  # `person_id`; dispatches one AddParticipant per person and flashes a
  # per-batch summary.
  def create
    authorize @session, :curate?
    ids = Array(params[:person_ids]).reject(&:blank?)
    ids = [ params.expect(:person_id) ] if ids.empty?

    added = 0
    failures = []
    ids.each do |person_id|
      Operations::CalibrationSessions::AddParticipant.call(
        context: pundit_user,
        params: { session_id: @session.id, person_id: person_id }
      )
      added += 1
    rescue Operations::Base::ParameterError, RuntimeError => e
      failures << e.message
    end

    if failures.empty?
      redirect_to calibration_session_path(@session),
                  notice: "#{added} #{'participant'.pluralize(added)} added."
    else
      redirect_to calibration_session_path(@session),
                  alert: "Added #{added}; skipped #{failures.size}: #{failures.uniq.join('; ')}"
    end
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
