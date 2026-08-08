# frozen_string_literal: true

# Rebuilds the drill-in URL an outcome POST (⚑ flag / revisit request) came
# from, so recording an outcome returns the room to the screen it was
# reading — which pane, the opened person, the compare pins, the wall's
# filters — rather than resetting it mid-conversation.
#
# The forms supply this state as hidden fields
# (`DrillInView#state_passthrough_fields`); everything here is untrusted
# query input, so each value is coerced to a scalar before it reaches a
# route helper (an array/hash `compare` otherwise raises out of the action).
module CalibrationSessions::DrillInReturnPath
  extend ActiveSupport::Concern

  private

  # @param session_record [CalibrationSession]
  # @param person_id [String, nil] the person card to re-open
  # @param extra [Hash] additional query params (e.g. forcing the log panel open)
  # @return [String]
  def drill_in_return_path(session_record, person_id: nil, extra: {})
    query = extra.merge(
      person: person_id.presence,
      pins: Array.wrap(params[:pins]).grep(String).select(&:present?).presence,
      view: params[:view].presence_in(CalibrationSessions::CapabilitiesController::VIEWS),
      wall_level: params[:wall_level].to_s.presence,
      wall_valence: params[:wall_valence].presence_in(EvidenceLink::VALENCES),
      wall_rater: params[:wall_rater].to_s.presence,
      # The focused strip level survives an outcome POST; the open form
      # (person_action) deliberately does NOT — the submit finished it.
      person_level: params[:person_level].to_s.presence
    ).compact

    calibration_session_capability_path(session_record, params[:capability_stable_id], query)
  end
end
