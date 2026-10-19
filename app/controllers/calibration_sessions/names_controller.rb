# frozen_string_literal: true

# Renames a calibration session — from the pencil on the session page's
# `<h1>` ({Views::CalibrationSessions::SessionNameFrame}) or from the index
# card's "Rename…" dialog. Dispatched through the shared
# Operations::CalibrationSessions::Rename, so the web and the
# `calibration_sessions_rename` MCP tool are one implementation.
#
# The pencil submits inside the name's Turbo Frame and gets the frame back; a
# rejected save answers 422 WITH the frame, the message and the typed text
# (framework-explorer.md, Hard-Won Lesson 26). The dialog is a plain form and
# gets a redirect back to where it was opened.
class CalibrationSessions::NamesController < ApplicationController
  before_action :set_session

  # PATCH /calibration_sessions/:id/name
  def update
    authorize @session, :rename?

    attempted = params.expect(calibration_session: [ :name ])[:name].to_s
    return refuse("the name can’t be blank", attempted) if attempted.blank?

    result = Operations::CalibrationSessions::Rename.call(
      context: pundit_user, params: { session_id: @session.id, name: attempted }
    )

    if turbo_frame_request?
      render_name_frame
    else
      redirect_back_or_to calibration_sessions_path, notice: "Renamed to “#{result[:name]}”."
    end
  rescue Operations::Base::ParameterError, RuntimeError => e
    refuse(e.message, attempted)
  end

  private

  def refuse(message, attempted)
    if turbo_frame_request?
      render_name_frame(error: message, attempted_value: attempted)
    else
      redirect_back_or_to calibration_sessions_path, alert: "Couldn’t rename: #{message}"
    end
  end

  def render_name_frame(error: nil, attempted_value: nil)
    render Views::CalibrationSessions::SessionNameFrame.new(
      session: @session.reload,
      can_rename: policy(@session).rename?,
      error: error,
      attempted_value: attempted_value
    ), layout: false, status: (error ? :unprocessable_content : :ok)
  end

  def set_session
    @session = CalibrationSession.find(params.expect(:id))
  rescue ActiveRecord::RecordNotFound
    redirect_to calibration_sessions_path
  end
end
