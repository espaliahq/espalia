# frozen_string_literal: true

# Reads a calibration session's outcome events from its stream — the
# follow-through material (expectation flags today; revisit requests and
# notes join as they are built). Read-time by design: outcomes are
# low-volume session artifacts, so no projection table is warranted
# (docs/architecture/calibration-sessions.md → "Outcomes").
class CalibrationSessions::SessionOutcomes
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

  private

  def stream_events
    @stream_events ||= @event_store.read
      .stream(EventStreamNaming.calibration_session_stream(@session.id))
      .to_a
  end
end
