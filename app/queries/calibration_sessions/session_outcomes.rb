# frozen_string_literal: true

# Reads a calibration session's outcome events from its stream — the
# follow-through material (expectation flags today; revisit requests and
# notes join as they are built). Read-time by design: outcomes are
# low-volume session artifacts, so no projection table is warranted
# (docs/architecture/calibration-sessions.md → "Outcomes").
class CalibrationSessions::SessionOutcomes
  # Most-recent events read per session. See #stream_events.
  STREAM_READ_LIMIT = 250

  # @param session [CalibrationSession]
  # @param event_store [RailsEventStore::Client]
  def initialize(session:, event_store: Rails.configuration.event_store)
    @session = session
    @event_store = event_store
  end

  # Expectation flags raised by this session, chronological.
  #
  # @return [Array<Hash>] `{ capability_stable_id:, level_ordinal:, suggestion_id:,
  #   flagged_by_id:, reason:, flagged_at: }`
  def flags
    @flags ||= stream_events
      .select { |e| e.is_a?(AssessmentCycles::Events::CalibrationExpectationFlagged) }
      .map do |event|
        data = event.data
        {
          capability_stable_id: data[:capability_stable_id],
          level_ordinal: data[:level_ordinal],
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
      *notes.map { |note| note.merge(kind: "note_recorded", at: note[:recorded_at], actor_id: note[:recorded_by_id]) }
    ].sort_by { |entry| entry[:at] || Time.at(0) }.reverse
  end

  private

  # Bounded, newest-first, then restored to chronological order.
  #
  # An unbounded `.to_a` made every read O(session lifetime): a long-running
  # session with hundreds of outcome events paid the whole stream on the
  # session page AND on drill-in renders. Reading the most recent
  # STREAM_READ_LIMIT makes it O(cap) instead — the same trade
  # Frameworks::ActivityFeedQuery makes.
  #
  # Trade-off, deliberately matching that precedent: an outcome older than
  # the cap drops off the log. Acceptable because the log is a session's
  # working record and the cap is far above a realistic session's output;
  # if sessions ever run past it, the fix is the same cursor "load older"
  # footer the framework feed has, not an unbounded read.
  def stream_events
    @stream_events ||= @event_store.read
      .stream(EventStreamNaming.calibration_session_stream(@session.id))
      .backward
      .limit(STREAM_READ_LIMIT)
      .to_a
      .reverse
  end
end
