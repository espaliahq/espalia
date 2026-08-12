# frozen_string_literal: true

require "set"

# Event-sourced aggregate for a calibration session.
#
# One RES stream per session: tenant-{tenant_id}/CalibrationSession-{session_id}.
#
# A calibration session is a facilitator-run forum where a set of
# participant raters (e.g. a department's EMs) compare how they rate
# their reports (the calibrants) against the framework's behavioural
# expectations. Sessions reference their assessment cycle but own
# their stream — many sessions can run concurrently within one cycle,
# and the same people may be calibrated in several sessions
# (department session, org-wide roll-up). See
# docs/architecture/calibration-sessions.md.
#
# Lifecycle: draft (participants + population editable) → started
# (both frozen) → closed. Cross-stream effects (closing open sessions
# when the cycle closes) happen via a sync handler, never from inside
# this aggregate.
#
# Load-bearing invariant: the calibrant population never intersects
# the raters in the room (participants ∪ {facilitator}) — participants
# are calibrated in a separate session run by their own manager.
#
class AssessmentCycles::CalibrationSessionAggregate
  include AggregateRoot

  CLOSE_REASONS = %w[facilitator cycle_closed].freeze

  def initialize
    @session_id = nil
    @cycle_id = nil
    @facilitator_id = nil
    @participant_ids = Set.new
    @calibrant_ids = Set.new
    @flagged_cells = Set.new
    @revisited_cells = Set.new
    @raised_request_ids = Set.new
    @status = :new
  end

  # Defines a new calibration session in draft state.
  #
  # The seeded calibrant list (typically the union of the participants'
  # reports, resolved by the caller) is curated further while in draft.
  #
  # @param session_id [String] UUID for the session
  # @param cycle_id [String] UUID of the assessment cycle
  # @param framework_id [String] UUID of the framework
  # @param name [String] display name
  # @param framework_version [Integer] framework version snapshot at define time
  # @param facilitator_id [String] person_id of the facilitator
  # @param participant_ids [Array<String>] person_ids of the participating raters
  # @param calibrant_person_ids [Array<String>] seeded population
  # @param defined_by [String, nil] person_id of the creator
  # @raise [RuntimeError] if already defined, blank name/facilitator, or the
  #   seeded population intersects the raters
  def define(session_id, cycle_id, framework_id, name, framework_version,
             facilitator_id:, participant_ids: [], calibrant_person_ids: [], defined_by: nil)
    raise "Session already defined" unless @status == :new
    raise "Name can't be blank" if name.to_s.strip.empty?
    raise "Facilitator is required" if facilitator_id.to_s.strip.empty?
    raise "Cycle is required" if cycle_id.to_s.strip.empty?

    participants = participant_ids.uniq
    calibrants = calibrant_person_ids.uniq
    overlap = calibrants & (participants + [ facilitator_id ])
    raise "Calibrants can't include session raters: #{overlap.join(', ')}" if overlap.any?

    apply(AssessmentCycles::Events::CalibrationSessionDefined.new(data: {
      session_id: session_id,
      cycle_id: cycle_id,
      framework_id: framework_id,
      framework_version: framework_version,
      name: name,
      facilitator_id: facilitator_id,
      participant_ids: participants,
      calibrant_person_ids: calibrants,
      defined_by: defined_by
    }))
  end

  # Adds a rater to the draft session. If the person is currently in
  # the calibrant population they are removed from it first
  # (reason "became_participant") — the invariant, kept as explicit
  # history rather than a silent side effect.
  #
  # @param participant_id [String] person_id of the rater to add
  # @param added_by [String, nil] person_id of the actor
  # @raise [RuntimeError] if not in draft or already a participant
  def add_participant(participant_id, added_by: nil)
    ensure_draft!
    raise "Already a participant" if @participant_ids.include?(participant_id)

    if @calibrant_ids.include?(participant_id)
      apply(AssessmentCycles::Events::CalibrationCalibrantRemoved.new(data: {
        session_id: @session_id,
        person_id: participant_id,
        reason: "became_participant",
        removed_by: added_by
      }))
    end

    apply(AssessmentCycles::Events::CalibrationParticipantAdded.new(data: {
      session_id: @session_id,
      participant_id: participant_id,
      added_by: added_by
    }))
  end

  # Removes a rater from the draft session. Their reports stay in the
  # population (curated list; raters-not-in-the-room are valid
  # reference points).
  #
  # @param participant_id [String] person_id of the rater to remove
  # @param removed_by [String, nil] person_id of the actor
  # @raise [RuntimeError] if not in draft or not a participant
  def remove_participant(participant_id, removed_by: nil)
    ensure_draft!
    raise "Not a participant" unless @participant_ids.include?(participant_id)

    apply(AssessmentCycles::Events::CalibrationParticipantRemoved.new(data: {
      session_id: @session_id,
      participant_id: participant_id,
      removed_by: removed_by
    }))
  end

  # Adds a person to the draft session's calibrant population.
  #
  # @param person_id [String] person_id to add
  # @param added_by [String, nil] person_id of the actor
  # @raise [RuntimeError] if not in draft, already a calibrant, or the
  #   person is a rater in this session (participant or facilitator)
  def add_calibrant(person_id, added_by: nil)
    ensure_draft!
    raise "Already a calibrant" if @calibrant_ids.include?(person_id)
    if @participant_ids.include?(person_id) || person_id == @facilitator_id
      raise "Session raters can't be calibrated in their own session"
    end

    apply(AssessmentCycles::Events::CalibrationCalibrantAdded.new(data: {
      session_id: @session_id,
      person_id: person_id,
      added_by: added_by
    }))
  end

  # Removes a person from the draft session's calibrant population.
  #
  # @param person_id [String] person_id to remove
  # @param removed_by [String, nil] person_id of the actor
  # @raise [RuntimeError] if not in draft or not a calibrant
  def remove_calibrant(person_id, removed_by: nil)
    ensure_draft!
    raise "Not a calibrant" unless @calibrant_ids.include?(person_id)

    apply(AssessmentCycles::Events::CalibrationCalibrantRemoved.new(data: {
      session_id: @session_id,
      person_id: person_id,
      reason: "manual",
      removed_by: removed_by
    }))
  end

  # Starts the session, freezing participants and population. The
  # frozen sets are carried on the event as snapshots so mid-session
  # org changes can never reshuffle the room.
  #
  # @param started_by_id [String, nil] person_id of the facilitator
  # @raise [RuntimeError] if not in draft, or no participants/calibrants
  def start(started_by_id: nil)
    ensure_draft!
    raise "Session needs at least one participant" if @participant_ids.empty?
    raise "Session needs at least one calibrant" if @calibrant_ids.empty?

    apply(AssessmentCycles::Events::CalibrationSessionStarted.new(data: {
      session_id: @session_id,
      participant_ids: @participant_ids.to_a,
      calibrant_person_ids: @calibrant_ids.to_a,
      started_by_id: started_by_id
    }))
  end

  # Records that the room flagged a capability × level expectation as
  # unclear. The framework-side clarification is raised FIRST by the caller
  # (two streams, not atomic — framework write leads; see
  # docs/architecture/calibration-sessions.md → "The clarification kind");
  # this event carries its suggestion_id as session provenance.
  #
  # One flag per cell per session — the room flags a cell once and the
  # discussion accumulates on the framework side (independent flags from
  # OTHER sessions stack there as separate clarifications by design).
  #
  # @param capability_stable_id [String] cross-version capability id
  # @param level_ordinal [Integer]
  # @param suggestion_id [String] the framework clarification's UUID
  # @param flagged_by_id [String, nil] person_id of the actor
  # @param reason [String, nil] the room's note on what is unclear
  # @raise [RuntimeError] unless the session is live, or the cell was
  #   already flagged in this session
  # `illustration_id` scopes an EXAMPLE flag: the uniqueness key includes
  # it, so the cell's expectation flag and each example's flag are
  # independent one-per-session outcomes (historic events carry nil, the
  # same key shape as an expectation flag).
  def flag_expectation(capability_stable_id:, level_ordinal:, suggestion_id:,
                       flagged_by_id: nil, reason: nil, illustration_id: nil)
    ensure_started!
    cell = [ capability_stable_id, level_ordinal, illustration_id ]
    if @flagged_cells.include?(cell)
      raise(illustration_id ? "Example already flagged in this session" : "Cell already flagged in this session")
    end

    apply(AssessmentCycles::Events::CalibrationExpectationFlagged.new(data: {
      session_id: @session_id,
      capability_stable_id: capability_stable_id,
      level_ordinal: level_ordinal,
      illustration_id: illustration_id,
      suggestion_id: suggestion_id,
      flagged_by_id: flagged_by_id,
      reason: reason
    }.compact))
  end

  # Asks a rater to revisit one of their manager ratings — a VALUE-FREE
  # nudge carrying the room's discussion note, never a target rating.
  # Mirrored onto the person's PD stream by a sync handler.
  #
  # The person must be in the (frozen) calibrant population, and the rater
  # must be a participant — you can't revisit-request a rater who isn't in
  # the room to hear the discussion. One request per (person, cell) per
  # session; the note is required (a nudge without the conversation's
  # context is noise).
  #
  # @param person_id [String] the calibrated person
  # @param capability_stable_id [String]
  # @param level_ordinal [Integer]
  # @param rater_id [String] the participant who owns the rating
  # @param note [String] the room's discussion note (required)
  # @param requested_by_id [String, nil] person_id of the actor
  # @raise [RuntimeError] on any invariant breach
  def request_rating_revisit(person_id:, capability_stable_id:, level_ordinal:,
                             rater_id:, note:, requested_by_id: nil)
    ensure_started!
    raise "Person is not in this session's population" unless @calibrant_ids.include?(person_id)
    raise "Rater is not a participant in this session" unless @participant_ids.include?(rater_id)
    raise "Revisit note cannot be blank" if note.to_s.strip.empty?
    cell = [ person_id, capability_stable_id, level_ordinal ]
    raise "Revisit already requested for this rating in this session" if @revisited_cells.include?(cell)

    apply(AssessmentCycles::Events::CalibrationRatingRevisitRequested.new(data: {
      session_id: @session_id,
      person_id: person_id,
      capability_stable_id: capability_stable_id,
      level_ordinal: level_ordinal,
      rater_id: rater_id,
      note: note,
      requested_by_id: requested_by_id
    }.compact))
  end

  # Records that this session fired a cell-scoped evidence request — the
  # provenance half of §f (the request itself already exists on the
  # person's PD stream; this event lets the follow-through page track it).
  # No one-per-cell rule: several people can legitimately be asked about
  # the same behaviour. Duplicate request_ids are refused so a retried
  # dispatch can't double-record one request.
  #
  # @param request_id [String] UUID of the EvidenceRequest being recorded
  # @param person_id [String] the calibrated person the ask is about
  # @param capability_stable_id [String]
  # @param level_ordinal [Integer]
  # @param requestee_id [String] person being asked
  # @param requested_by_id [String, nil] person_id of the actor
  # @raise [RuntimeError] on any invariant breach
  def raise_evidence_request(request_id:, person_id:, capability_stable_id:,
                             level_ordinal:, requestee_id:, message: nil,
                             requested_by_id: nil)
    ensure_started!
    raise "Person is not in this session's population" unless @calibrant_ids.include?(person_id)
    raise "Request id cannot be blank" if request_id.to_s.strip.empty?
    raise "Request already recorded in this session" if @raised_request_ids.include?(request_id)

    apply(AssessmentCycles::Events::CalibrationEvidenceRequestRaised.new(data: {
      session_id: @session_id,
      request_id: request_id,
      person_id: person_id,
      capability_stable_id: capability_stable_id,
      level_ordinal: level_ordinal,
      requestee_id: requestee_id,
      message: message,
      requested_by_id: requested_by_id
    }.compact))
  end

  # Records a free-text session minute, optionally anchored to a
  # capability or a calibrant. Live sessions only — the note narrates the
  # room.
  #
  # @param body [String] the note (required)
  # @param capability_stable_id [String, nil] optional capability anchor
  # @param person_id [String, nil] optional person anchor (must be a calibrant)
  # @param recorded_by_id [String, nil] person_id of the actor
  # @raise [RuntimeError] unless live, body present, and any person anchor
  #   is in the population
  def record_note(body:, capability_stable_id: nil, person_id: nil, recorded_by_id: nil)
    ensure_started!
    raise "Note cannot be blank" if body.to_s.strip.empty?
    if person_id && !@calibrant_ids.include?(person_id)
      raise "Note anchor is not in this session's population"
    end

    apply(AssessmentCycles::Events::CalibrationNoteRecorded.new(data: {
      session_id: @session_id,
      body: body,
      capability_stable_id: capability_stable_id,
      person_id: person_id,
      recorded_by_id: recorded_by_id
    }.compact))
  end

  # Closes the session (terminal). No-op when already closed so the
  # cycle-close sync handler is retry-safe.
  #
  # @param reason [String] "facilitator" or "cycle_closed"
  # @param closed_by_id [String, nil] person_id of the closer
  # @raise [RuntimeError] if never defined or invalid reason
  def close(reason: "facilitator", closed_by_id: nil)
    raise "Session not defined" if @status == :new
    raise "Invalid close reason: #{reason}" unless CLOSE_REASONS.include?(reason)
    return if @status == :closed

    apply(AssessmentCycles::Events::CalibrationSessionClosed.new(data: {
      session_id: @session_id,
      reason: reason,
      closed_by_id: closed_by_id
    }))
  end

  private

  def ensure_draft!
    raise "Session not defined" if @status == :new
    raise "Session already started — participants and population are frozen" if @status == :started
    raise "Session is closed" if @status == :closed
  end

  # Outcomes are live-session acts: a draft session has no room to speak
  # for, and a closed one is history.
  def ensure_started!
    raise "Session not defined" if @status == :new
    raise "Session hasn't started" if @status == :draft
    raise "Session is closed" if @status == :closed
  end

  # ── Event handlers ──

  on AssessmentCycles::Events::CalibrationSessionDefined do |event|
    @session_id = event.data[:session_id]
    @cycle_id = event.data[:cycle_id]
    @facilitator_id = event.data[:facilitator_id]
    @participant_ids = Set.new(event.data[:participant_ids])
    @calibrant_ids = Set.new(event.data[:calibrant_person_ids])
    @status = :draft
  end

  on AssessmentCycles::Events::CalibrationParticipantAdded do |event|
    @participant_ids << event.data[:participant_id]
  end

  on AssessmentCycles::Events::CalibrationParticipantRemoved do |event|
    @participant_ids.delete(event.data[:participant_id])
  end

  on AssessmentCycles::Events::CalibrationCalibrantAdded do |event|
    @calibrant_ids << event.data[:person_id]
  end

  on AssessmentCycles::Events::CalibrationCalibrantRemoved do |event|
    @calibrant_ids.delete(event.data[:person_id])
  end

  on AssessmentCycles::Events::CalibrationSessionStarted do |_event|
    @status = :started
  end

  on AssessmentCycles::Events::CalibrationExpectationFlagged do |event|
    @flagged_cells << [ event.data[:capability_stable_id], event.data[:level_ordinal],
                        event.data[:illustration_id] ]
  end

  on AssessmentCycles::Events::CalibrationRatingRevisitRequested do |event|
    @revisited_cells << [ event.data[:person_id], event.data[:capability_stable_id],
                          event.data[:level_ordinal] ]
  end

  on AssessmentCycles::Events::CalibrationEvidenceRequestRaised do |event|
    @raised_request_ids << event.data[:request_id]
  end

  on AssessmentCycles::Events::CalibrationNoteRecorded do |_event|
    # Notes carry no invariant state — SessionOutcomes reads them from the
    # stream for the session log.
  end

  on AssessmentCycles::Events::CalibrationSessionClosed do |_event|
    @status = :closed
  end
end
