# frozen_string_literal: true

# Reads a calibration session's outcome events — expectation flags, revisit
# requests, evidence requests, and notes — from its stream.
#
# Read-time by design: a session's outcome count is bounded by one meeting's
# discussion, so a projection table would carry rebuild and ownership cost
# for a handful of rows (docs/architecture/calibration-sessions.md →
# "Read models", which records the decision rather than pointing back here).
class CalibrationSessions::SessionOutcomes
  # The outcome events, in stream order. Read as a set so the query
  # skips the definition / curation / agenda / lifecycle events the stream
  # also carries.
  OUTCOME_EVENTS = [
    AssessmentCycles::Events::CalibrationExpectationFlagged,
    AssessmentCycles::Events::CalibrationRatingRevisitRequested,
    AssessmentCycles::Events::CalibrationEvidenceRequestRaised,
    AssessmentCycles::Events::CalibrationNoteRecorded
  ].freeze

  # Outcome counts for the session list, one counting read per session —
  # the list is a handful of sessions per cycle, and a draft has none, so
  # pass only the sessions that can have any.
  #
  # @param sessions [Array<CalibrationSession>]
  # @return [Hash{String => Integer}] session id → outcome count
  def self.counts_for(sessions, event_store: Rails.configuration.event_store)
    sessions.to_h { |session| [ session.id, new(session: session, event_store: event_store).count ] }
  end

  # @param session [CalibrationSession]
  # @param event_store [RailsEventStore::Client]
  def initialize(session:, event_store: Rails.configuration.event_store)
    @session = session
    @event_store = event_store
  end

  # How many outcomes the session recorded, without loading them.
  #
  # @return [Integer]
  def count
    @event_store.read.stream(stream_name).of_type(OUTCOME_EVENTS).count
  end

  # Expectation flags raised by this session, chronological.
  #
  # @return [Array<Hash>] `{ capability_stable_id:, level_ordinal:, suggestion_id:,
  #   flagged_by_id:, reason:, flagged_at: }`
  # @return [Array<Hash>] one entry per flag —
  #   `{ capability_stable_id:, level_ordinal:, illustration_id:,
  #   suggestion_id:, flagged_by_id:, reason:, flagged_at: }`;
  #   `illustration_id` is non-nil for an EXAMPLE flag (one role
  #   illustration under the cell) and nil for the cell's expectation flag.
  def flags
    @flags ||= stream_events
      .select { |e| e.is_a?(AssessmentCycles::Events::CalibrationExpectationFlagged) }
      .map do |event|
        data = event.data
        {
          capability_stable_id: data[:capability_stable_id],
          level_ordinal: data[:level_ordinal],
          illustration_id: data[:illustration_id],
          suggestion_id: data[:suggestion_id],
          flagged_by_id: data[:flagged_by_id],
          reason: data[:reason],
          flagged_at: event.metadata[:timestamp]
        }
      end
  end

  # Rating-revisit requests raised by this session, chronological.
  #
  # @return [Array<Hash>] `{ person_id:, capability_stable_id:, level_ordinal:,
  #   rater_id:, note:, requested_by_id:, requested_at: }`
  def revisit_requests
    @revisit_requests ||= stream_events
      .select { |e| e.is_a?(AssessmentCycles::Events::CalibrationRatingRevisitRequested) }
      .map do |event|
        data = event.data
        {
          person_id: data[:person_id],
          capability_stable_id: data[:capability_stable_id],
          level_ordinal: data[:level_ordinal],
          rater_id: data[:rater_id],
          note: data[:note],
          requested_by_id: data[:requested_by_id],
          requested_at: event.metadata[:timestamp]
        }
      end
  end

  # Evidence requests fired by this session, chronological. Fulfilment is
  # NOT here — read it from {EvidenceRequest} by request_id at render time.
  #
  # @return [Array<Hash>] `{ request_id:, person_id:, capability_stable_id:,
  #   level_ordinal:, requestee_id:, requested_by_id:, requested_at: }`
  def evidence_requests
    @evidence_requests ||= stream_events
      .select { |e| e.is_a?(AssessmentCycles::Events::CalibrationEvidenceRequestRaised) }
      .map do |event|
        data = event.data
        {
          request_id: data[:request_id],
          person_id: data[:person_id],
          capability_stable_id: data[:capability_stable_id],
          level_ordinal: data[:level_ordinal],
          requestee_id: data[:requestee_id],
          message: data[:message],
          requested_by_id: data[:requested_by_id],
          requested_at: event.metadata[:timestamp]
        }
      end
  end

  # Free-text minutes recorded by this session, chronological.
  #
  # @return [Array<Hash>] `{ body:, capability_stable_id:, person_id:,
  #   recorded_by_id:, recorded_at: }`
  def notes
    @notes ||= stream_events
      .select { |e| e.is_a?(AssessmentCycles::Events::CalibrationNoteRecorded) }
      .map do |event|
        data = event.data
        {
          body: data[:body],
          capability_stable_id: data[:capability_stable_id],
          person_id: data[:person_id],
          recorded_by_id: data[:recorded_by_id],
          recorded_at: event.metadata[:timestamp]
        }
      end
  end

  # Every outcome as one reverse-chronological feed, in the shape the
  # product's activity panels render (kind + actor + timestamp + payload).
  # The session log reads this instead of three separate sections: a
  # session's story is one thread — a flag, then the note it prompted,
  # then the revisit it produced — and splitting it by type hides that.
  #
  # @return [Array<Hash>] newest first; each `{ kind:, at:, actor_id:, … }`
  #   plus the type's own keys
  def entries
    @entries ||= [
      *flags.map { |flag| flag.merge(kind: "expectation_flagged", at: flag[:flagged_at], actor_id: flag[:flagged_by_id]) },
      *revisit_requests.map { |r| r.merge(kind: "revisit_requested", at: r[:requested_at], actor_id: r[:requested_by_id]) },
      *evidence_requests.map { |r| r.merge(kind: "evidence_requested", at: r[:requested_at], actor_id: r[:requested_by_id]) },
      *notes.map { |note| note.merge(kind: "note_recorded", at: note[:recorded_at], actor_id: note[:recorded_by_id]) }
    ].sort_by { |entry| entry[:at] || Time.at(0) }.reverse
  end

  private

  # One type-filtered read per instance, chronological.
  #
  # Deliberately UNBOUNDED. These reads are not only a feed: PersonCard
  # suppresses an already-asked revisit from them, and FlagExpectation
  # pre-checks an already-flagged cell — so an event dropped by a cap
  # becomes an affordance the aggregate then refuses. The cap belongs on
  # what is RENDERED (SessionLog::RENDER_LIMIT), not on what is known.
  #
  # `of_type` is what keeps this cheap: a session stream also carries
  # definition, curation, agenda and lifecycle events, and outcomes are
  # bounded by one meeting's discussion. The instance is shared across a
  # render (see CapabilitiesController) so the read happens once.
  def stream_events
    @stream_events ||= @event_store.read
      .stream(stream_name)
      .of_type(OUTCOME_EVENTS)
      .to_a
  end

  def stream_name
    EventStreamNaming.calibration_session_stream(@session.id)
  end
end
