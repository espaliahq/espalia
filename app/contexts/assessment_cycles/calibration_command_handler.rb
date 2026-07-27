# frozen_string_literal: true

# Handles commands for CalibrationSession aggregates.
#
# Loads the aggregate via the shared AssessmentCycles repository,
# executes the command, and stores resulting events. Separate from
# {AssessmentCycles::CommandHandler} because sessions are a distinct
# aggregate with their own stream — see
# docs/architecture/calibration-sessions.md.
#
class AssessmentCycles::CalibrationCommandHandler
  # @param repository [AssessmentCycles::Repository]
  def initialize(repository: AssessmentCycles::Repository.new)
    @repository = repository
  end

  # Defines a new calibration session in draft state.
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
  def define_session(session_id, cycle_id, framework_id, name, framework_version,
                     facilitator_id:, participant_ids: [], calibrant_person_ids: [], defined_by: nil)
    @repository.with_calibration_session(session_id) do |session|
      session.define(session_id, cycle_id, framework_id, name, framework_version,
                     facilitator_id: facilitator_id,
                     participant_ids: participant_ids,
                     calibrant_person_ids: calibrant_person_ids,
                     defined_by: defined_by)
    end
  end

  # Adds a rater to a draft session (auto-removing them from the
  # calibrant population if present).
  #
  # @param session_id [String]
  # @param participant_id [String] person_id of the rater
  # @param added_by [String, nil]
  def add_participant(session_id, participant_id, added_by: nil)
    @repository.with_calibration_session(session_id) do |session|
      session.add_participant(participant_id, added_by: added_by)
    end
  end

  # Removes a rater from a draft session.
  #
  # @param session_id [String]
  # @param participant_id [String] person_id of the rater
  # @param removed_by [String, nil]
  def remove_participant(session_id, participant_id, removed_by: nil)
    @repository.with_calibration_session(session_id) do |session|
      session.remove_participant(participant_id, removed_by: removed_by)
    end
  end

  # Adds a person to a draft session's calibrant population.
  #
  # @param session_id [String]
  # @param person_id [String]
  # @param added_by [String, nil]
  def add_calibrant(session_id, person_id, added_by: nil)
    @repository.with_calibration_session(session_id) do |session|
      session.add_calibrant(person_id, added_by: added_by)
    end
  end

  # Removes a person from a draft session's calibrant population.
  #
  # @param session_id [String]
  # @param person_id [String]
  # @param removed_by [String, nil]
  def remove_calibrant(session_id, person_id, removed_by: nil)
    @repository.with_calibration_session(session_id) do |session|
      session.remove_calibrant(person_id, removed_by: removed_by)
    end
  end

  # Starts a session, freezing participants and population.
  #
  # @param session_id [String]
  # @param started_by_id [String, nil]
  def start_session(session_id, started_by_id: nil)
    @repository.with_calibration_session(session_id) do |session|
      session.start(started_by_id: started_by_id)
    end
  end

  # Records that a live session flagged a capability × level expectation
  # as unclear, carrying the framework clarification's suggestion_id.
  #
  # @param session_id [String]
  # @param capability_stable_id [String]
  # @param level_ordinal [Integer]
  # @param suggestion_id [String] the framework clarification's UUID
  # @param flagged_by_id [String, nil]
  # @param reason [String, nil]
  def flag_expectation(session_id, capability_stable_id:, level_ordinal:, suggestion_id:,
                       flagged_by_id: nil, reason: nil)
    @repository.with_calibration_session(session_id) do |session|
      session.flag_expectation(
        capability_stable_id: capability_stable_id, level_ordinal: level_ordinal,
        suggestion_id: suggestion_id, flagged_by_id: flagged_by_id, reason: reason
      )
    end
  end

  # Asks a rater to revisit one of their manager ratings (value-free —
  # the note is the payload, never a target rating). Mirrored to the
  # person's PD stream by CalibrationRevisitSync.
  #
  # @param session_id [String]
  # @param person_id [String] the calibrated person
  # @param capability_stable_id [String]
  # @param level_ordinal [Integer]
  # @param rater_id [String] the participant who owns the rating
  # @param note [String]
  # @param requested_by_id [String, nil]
  def request_rating_revisit(session_id, person_id:, capability_stable_id:, level_ordinal:,
                             rater_id:, note:, requested_by_id: nil)
    @repository.with_calibration_session(session_id) do |session|
      session.request_rating_revisit(
        person_id: person_id, capability_stable_id: capability_stable_id,
        level_ordinal: level_ordinal, rater_id: rater_id, note: note,
        requested_by_id: requested_by_id
      )
    end
  end

  # Records a free-text session minute (live sessions only).
  #
  # @param session_id [String]
  # @param body [String]
  # @param capability_stable_id [String, nil]
  # @param person_id [String, nil]
  # @param recorded_by_id [String, nil]
  def record_note(session_id, body:, capability_stable_id: nil, person_id: nil, recorded_by_id: nil)
    @repository.with_calibration_session(session_id) do |session|
      session.record_note(body: body, capability_stable_id: capability_stable_id,
                          person_id: person_id, recorded_by_id: recorded_by_id)
    end
  end

  # Closes a session. No-op when already closed (the cycle-close sync
  # path relies on this).
  #
  # @param session_id [String]
  # @param reason [String] "facilitator" or "cycle_closed"
  # @param closed_by_id [String, nil]
  def close_session(session_id, reason: "facilitator", closed_by_id: nil)
    @repository.with_calibration_session(session_id) do |session|
      session.close(reason: reason, closed_by_id: closed_by_id)
    end
  end
end
