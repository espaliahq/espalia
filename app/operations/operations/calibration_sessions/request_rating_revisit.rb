# frozen_string_literal: true

# Asks a rater to revisit one of their manager ratings from a live
# calibration session — a VALUE-FREE nudge (the discussion note is the
# payload, never a target rating; notes compose across overlapping
# sessions, target values manufacture contradictions).
#
# The session-stream event is the source of truth;
# {AssessmentCycles::SyncHandlers::CalibrationRevisitSync} mirrors it onto
# the person's PD stream in the same transaction, so the nudge surfaces in
# the rater's assessment activity feed. Resolution is rating-change-based
# and computed at read time.
#
# The rater is resolved server-side (the participant the person's ratings
# are attributed to) and must be in the room — no revisit requests against
# a rater who isn't present to hear the discussion.
class Operations::CalibrationSessions::RequestRatingRevisit < Operations::Base
  include Operations::CalibrationSessions::ScopeChecks

  description "Ask a rater to revisit a manager rating from a live calibration session — value-free, with the room's note."
  category :write
  approval :mcp_client

  parameter :session_id, String, required: true
  parameter :person_id, String, required: true
  parameter :capability_stable_id, String, required: true
  parameter :level_ordinal, Integer, required: true
  # The room's discussion note — required; a nudge without context is noise.
  parameter :note, String, required: true

  def policy_check
    authorize session, :flag_expectation?
  end

  # @return [Hash] `{ session_id, person_id, capability_stable_id, level_ordinal, rater_id }`
  def perform
    ensure_uuid!(:person_id, params[:person_id])
    ensure_uuid!(:capability_stable_id, params[:capability_stable_id])
    ensure_session_started!
    ensure_note!
    ensure_rater_in_session!

    begin
      command_handler.request_rating_revisit(
        session.id,
        person_id: params[:person_id],
        capability_stable_id: params[:capability_stable_id],
        level_ordinal: params[:level_ordinal],
        rater_id: rater_id,
        note: params[:note],
        requested_by_id: context.person&.id
      )
    rescue PersonDevelopment::Aggregate::CommandError, RuntimeError => e
      # Aggregate refusals from either stream — the session's own guards
      # (duplicate ask, lifecycle) or the same-transaction PD mirror
      # (CalibrationRevisitSync; e.g. the person was unassigned after the
      # population froze) — are client-state problems, not server bugs:
      # classify as invalid params (→ -32602 over MCP, a flash on the web),
      # never an opaque 500/-32603.
      raise Operations::Base::ParameterError, e.message
    end

    {
      session_id: session.id,
      person_id: params[:person_id],
      capability_stable_id: params[:capability_stable_id],
      level_ordinal: params[:level_ordinal],
      rater_id: rater_id
    }
  end

  private

  def ensure_session_started!
    return if session.started?

    raise Operations::Base::ParameterError,
          "session is #{session.status} — revisit requests come from a live session"
  end

  def ensure_note!
    return if params[:note].strip.present?

    raise Operations::Base::ParameterError, "note can't be blank — carry the room's discussion"
  end

  def ensure_rater_in_session!
    return if rater_id.present?

    raise Operations::Base::ParameterError,
          "this person's rater is not a participant in this session — reference points are exempt from outcomes"
  end

  # The participant this person's ratings are attributed to — the CANONICAL
  # PopulationSeeds#attribution the drill-in grid and tendency strip also
  # read, so the rater named on the card is exactly the rater recorded on
  # the event (and notified). nil when their rater isn't in the room.
  def rater_id
    @rater_id ||= CalibrationSessions::PopulationSeeds.new(
      framework_id: session.framework_id,
      participant_ids: session.participants.pluck(:person_id),
      facilitator_id: session.facilitator_id
    ).attribution[params[:person_id]]
  end
end
