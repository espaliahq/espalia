# frozen_string_literal: true

# Handles commands for the PersonDevelopment aggregate.
#
# Loads the aggregate via the repository, executes the command,
# and stores resulting events.
#
class PersonDevelopment::CommandHandler
  CURRENT_CYCLE = Object.new.freeze

  # @param repository [PersonDevelopment::Repository]
  def initialize(repository: PersonDevelopment::Repository.new)
    @repository = repository
  end

  # Assigns a person to a framework with a role and level.
  #
  # @param person_id [String] UUID of the person
  # @param framework_id [String] UUID of the framework
  # @param role_id [String] UUID of the assigned role
  # @param level_id [String] UUID of the assigned level
  # @param assigned_by [String, nil] UUID of the Person who triggered the
  #   assignment; nil for system-driven HRIS syncs
  def assign_to_framework(person_id, framework_id, role_id, level_id, assigned_by: nil)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.assign_to_framework(person_id, framework_id, role_id, level_id, assigned_by: assigned_by)
    end
  end

  # Changes a person's role (and level) within their current framework.
  #
  # @param person_id [String] UUID of the person
  # @param framework_id [String] UUID of the framework
  # @param new_role_id [String] UUID of the new role
  # @param new_level_id [String] UUID of the new level
  # @param reason [String] why the change occurred
  # @param changed_by [String, nil] UUID of the Person who triggered the change;
  #   nil for system-driven HRIS syncs
  def change_person_role(person_id, framework_id, new_role_id, new_level_id, reason: "hris_sync",
                         changed_by: nil)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.change_role(new_role_id, new_level_id, reason: reason, changed_by: changed_by)
    end
  end

  # Changes a person's level within the same role (promotion).
  #
  # @param person_id [String] UUID of the person
  # @param framework_id [String] UUID of the framework
  # @param new_level_id [String] UUID of the new level
  # @param reason [String] why the change occurred
  # @param changed_by [String, nil] UUID of the Person who triggered the change;
  #   nil for system-driven HRIS syncs
  def change_person_level(person_id, framework_id, new_level_id, reason: "hris_sync", changed_by: nil)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.change_level(new_level_id, reason: reason, changed_by: changed_by)
    end
  end

  # Removes a person's framework assignment entirely (the exit from the
  # assign → change_role → change_level lifecycle). The full history stays on
  # the stream; only the assignment read-model row is removed.
  #
  # @param person_id [String] UUID of the person
  # @param framework_id [String] UUID of the framework
  # @param reason [String] why the assignment was removed
  # @param unassigned_by [String, nil] UUID of the Person who triggered it;
  #   nil for system-driven actions
  # @raise [RuntimeError] if not assigned, or still enrolled in a cycle
  def unassign_from_framework(person_id, framework_id, reason: "manual", unassigned_by: nil)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.unassign_from_framework(reason: reason, unassigned_by: unassigned_by)
    end
  end

  # Records the person's reporting manager on their stream (idempotent — no-op
  # when unchanged). Populated from HRIS sync and the one-off backfill.
  #
  # @param person_id [String] UUID of the person
  # @param framework_id [String] UUID of the framework
  # @param manager_id [String, nil] UUID of the reporting manager
  # @param source [String] "hris" or "backfill"
  def record_reporting_manager(person_id, framework_id, manager_id, source: "hris")
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.record_reporting_manager(manager_id, source: source)
    end
  end

  # Grants manager-rating authority for this person/framework to a delegate.
  #
  # @param person_id [String] UUID of the person being assessed
  # @param framework_id [String] UUID of the framework
  # @param delegate_person_id [String] UUID of the delegate
  # @param granted_by_id [String] UUID of the granter
  # @param expires_at [String, Time, nil] optional expiry
  # @param reason [String, nil] optional note
  def delegate_manager_rating(person_id, framework_id, delegate_person_id, granted_by_id:,
                              expires_at: nil, reason: nil)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.delegate_manager_rating(delegate_person_id, granted_by_id: granted_by_id,
        expires_at: expires_at, reason: reason)
    end
  end

  # Mirrors a calibration session's rating-revisit request onto the person's
  # stream (invoked only by CalibrationRevisitSync).
  #
  # @param person_id [String] UUID of the calibrated person
  # @param framework_id [String] UUID of the framework
  # @param capability_stable_id [String]
  # @param level_ordinal [Integer]
  # @param calibration_session_id [String]
  # @param rater_id [String] the rater being asked
  # @param note [String] the room's discussion note
  # @param session_name [String, nil]
  # @param requested_by_id [String, nil]
  def request_rating_revisit(person_id, framework_id, capability_stable_id:, level_ordinal:,
                             calibration_session_id:, rater_id:, note:,
                             session_name: nil, requested_by_id: nil)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.request_rating_revisit(
        capability_stable_id: capability_stable_id, level_ordinal: level_ordinal,
        calibration_session_id: calibration_session_id, rater_id: rater_id,
        note: note, session_name: session_name, requested_by_id: requested_by_id
      )
    end
  end

  # Declares an exploration of another role or level (ADR-22).
  #
  # @param person_id [String] UUID of the person exploring
  # @param framework_id [String] UUID of the framework
  # @param exploration_id [String] caller-minted UUID v7
  # @param target_role_id [String]
  # @param target_level_id [String]
  # @param target_level_ordinal [Integer]
  # @param started_by_id [String, nil]
  # @param note [String, nil]
  def start_exploration(person_id, framework_id, exploration_id, target_role_id:, target_level_id:,
                        target_level_ordinal:, started_by_id:, note: nil)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.start_exploration(exploration_id, target_role_id: target_role_id, target_level_id: target_level_id,
                                  target_level_ordinal: target_level_ordinal, started_by_id: started_by_id,
                                  note: note)
    end
  end

  # Closes a declared exploration with its outcome (ADR-22).
  #
  # @param person_id [String]
  # @param framework_id [String]
  # @param exploration_id [String]
  # @param closed_by_id [String, nil]
  # @param outcome [String] "pursue" | "not_now" | "moved"
  # @param note [String, nil]
  def close_exploration(person_id, framework_id, exploration_id, closed_by_id:, outcome:, note: nil)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.close_exploration(exploration_id, closed_by_id: closed_by_id, outcome: outcome, note: note)
    end
  end

  # Revokes a manager-rating delegation (non-destructive).
  #
  # @param person_id [String] UUID of the person being assessed
  # @param framework_id [String] UUID of the framework
  # @param delegate_person_id [String] UUID of the delegate
  # @param revoked_by_id [String] UUID of the revoker
  def revoke_manager_rating_delegation(person_id, framework_id, delegate_person_id, revoked_by_id:)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.revoke_manager_rating_delegation(delegate_person_id, revoked_by_id: revoked_by_id)
    end
  end

  # Adds the person to an assessment cycle.
  #
  # Called ONLY by {AssessmentCycles::SyncHandlers::PersonEnrollmentSync}
  # in response to a PersonEnrolled event — never by controllers.
  #
  # @param person_id [String] UUID of the person
  # @param framework_id [String] UUID of the framework
  # @param cycle_id [String] UUID of the cycle to join
  # @param framework_version [Integer] framework version the cycle assesses against
  def join_cycle(person_id, framework_id, cycle_id, framework_version)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.join_cycle(cycle_id, framework_version)
    end
  end

  # Migrates this person's stream onto a newly published framework version.
  #
  # Called ONLY by {Frameworks::SyncHandlers::FrameworkVersionMigrationSync}
  # in the same transaction as the originating
  # {Frameworks::Events::FrameworkVersionPublished}.
  #
  # @param person_id [String] UUID of the person
  # @param framework_id [String] UUID of the framework
  # @param old_version [Integer] previous published version
  # @param new_version [Integer] newly published version
  # @param mappings [Array<Hash>] migration mappings; see
  #   {PersonDevelopment::Events::FrameworkVersionMigrated} for shape
  def migrate_framework_version(person_id, framework_id, old_version, new_version, mappings)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.migrate_framework_version(framework_id, old_version, new_version, mappings)
    end
  end

  # Removes the person from their current assessment cycle (person-scoped
  # removal — cycle closure goes through {#conclude_cycle} instead).
  #
  # Called ONLY by {AssessmentCycles::SyncHandlers::PersonEnrollmentSync}
  # in response to a PersonUnenrolled event — never by controllers.
  #
  # @param person_id [String] UUID of the person
  # @param framework_id [String] UUID of the framework
  # @param cycle_id [String] UUID of the cycle being left (must match current)
  # @param reason [String] why the person is leaving
  def leave_cycle(person_id, framework_id, cycle_id, reason)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.leave_cycle(cycle_id, reason)
    end
  end

  # Concludes the person's current assessment cycle (the cycle closed with
  # them still enrolled — a normal ending, not a removal).
  #
  # Called ONLY by {AssessmentCycles::SyncHandlers::PersonEnrollmentSync}
  # in response to a CycleClosed event — never by controllers.
  #
  # @param person_id [String] UUID of the person
  # @param framework_id [String] UUID of the framework
  # @param cycle_id [String] UUID of the cycle that concluded (must match current)
  def conclude_cycle(person_id, framework_id, cycle_id)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.conclude_cycle(cycle_id)
    end
  end

  # Records a self-rating for a capability at a specific level.
  #
  # @param person_id [String] UUID of the person
  # @param framework_id [String] UUID of the framework
  # @param capability_stable_id [String] stable UUID of the capability
  # @param level_ordinal [Integer] the level being assessed
  # @param frequency [String] "some", "occasional", or "consistent"
  # @param cycle_id [String] UUID of the cycle this rating belongs to
  # @param comment [String, nil] optional rationale
  # @param source [String] "human" (default) when entered by the person, or
  #   "seeded" when carried over from a prior cycle's aligned value at cycle join
  # @param seeded_from_cycle_id [String, nil] UUID of the originating cycle when
  #   source == "seeded"; nil otherwise
  # @param via_role_id [String, nil] the role whose cells the rater was reading
  #   through a lens (ADR-22) — provenance only; nil for the home role
  def rate_self(person_id, framework_id, capability_stable_id,
                level_ordinal:, frequency:, cycle_id:, comment: nil,
                source: "human", seeded_from_cycle_id: nil, via_role_id: nil)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.rate_self(capability_stable_id, level_ordinal: level_ordinal,
        frequency: frequency, cycle_id: cycle_id, comment: comment,
        source: source, seeded_from_cycle_id: seeded_from_cycle_id, via_role_id: via_role_id)
    end
  end

  # Revises a previous self-rating.
  #
  # @param person_id [String] UUID of the person
  # @param framework_id [String] UUID of the framework
  # @param capability_stable_id [String] stable UUID of the capability
  # @param level_ordinal [Integer] the level being revised
  # @param frequency [String] revised frequency
  # @param rationale [String] reason for the change
  # @param cycle_id [String] UUID of the cycle this rating belongs to
  # @param comment [String, nil] optional comment
  # @param via_role_id [String, nil] lens provenance — see {#rate_self}
  def revise_self_rating(person_id, framework_id, capability_stable_id,
                         level_ordinal:, frequency:, rationale:, cycle_id:, comment: nil, via_role_id: nil)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.revise_self_rating(capability_stable_id, level_ordinal: level_ordinal,
        frequency: frequency, rationale: rationale, cycle_id: cycle_id, comment: comment,
        via_role_id: via_role_id)
    end
  end

  # Clears a previous self-rating.
  #
  # @param person_id [String] UUID of the person
  # @param framework_id [String] UUID of the framework
  # @param capability_stable_id [String] stable UUID of the capability
  # @param level_ordinal [Integer] the level being cleared
  # @param cycle_id [String] UUID of the cycle this rating belongs to
  def clear_self_rating(person_id, framework_id, capability_stable_id, level_ordinal:, cycle_id:)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.clear_self_rating(capability_stable_id, level_ordinal: level_ordinal, cycle_id: cycle_id)
    end
  end

  # Records a manager's rating for a person's capability at a specific level.
  #
  # @param person_id [String] UUID of the person being rated
  # @param framework_id [String] UUID of the framework
  # @param capability_stable_id [String] stable UUID of the capability
  # @param level_ordinal [Integer] the level being assessed
  # @param frequency [String] "some", "occasional", or "consistent"
  # @param cycle_id [String] UUID of the cycle this rating belongs to
  # @param comment [String, nil] optional rationale
  # @param source [String] "human" (default) when entered by the manager, or
  #   "seeded" when carried over from a prior cycle's aligned value at cycle join
  # @param seeded_from_cycle_id [String, nil] UUID of the originating cycle when
  #   source == "seeded"; nil otherwise
  # @param rated_by_id [String, nil] UUID of the manager recording the rating;
  #   nil for system "seeded" carry-forwards
  # @param via_role_id [String, nil] lens provenance — see {#rate_self}
  def rate_as_manager(person_id, framework_id, capability_stable_id,
                      level_ordinal:, frequency:, cycle_id:, comment: nil,
                      source: "human", seeded_from_cycle_id: nil, rated_by_id: nil, via_role_id: nil)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.rate_as_manager(capability_stable_id, level_ordinal: level_ordinal,
        frequency: frequency, cycle_id: cycle_id, comment: comment,
        source: source, seeded_from_cycle_id: seeded_from_cycle_id, rated_by_id: rated_by_id,
        via_role_id: via_role_id)
    end
  end

  # Revises a previous manager rating.
  #
  # @param person_id [String] UUID of the person being rated
  # @param framework_id [String] UUID of the framework
  # @param capability_stable_id [String] stable UUID of the capability
  # @param level_ordinal [Integer] the level being revised
  # @param frequency [String] revised frequency
  # @param rationale [String] reason for the change
  # @param cycle_id [String] UUID of the cycle this rating belongs to
  # @param comment [String, nil] optional comment
  # @param rated_by_id [String, nil] UUID of the manager recording the revision
  # @param via_role_id [String, nil] lens provenance — see {#rate_self}
  def revise_manager_rating(person_id, framework_id, capability_stable_id,
                            level_ordinal:, frequency:, rationale:, cycle_id:, comment: nil,
                            rated_by_id: nil, via_role_id: nil)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.revise_manager_rating(capability_stable_id, level_ordinal: level_ordinal,
        frequency: frequency, rationale: rationale, cycle_id: cycle_id, comment: comment,
        rated_by_id: rated_by_id, via_role_id: via_role_id)
    end
  end

  # Clears a previous manager rating.
  #
  # @param person_id [String] UUID of the person being rated
  # @param framework_id [String] UUID of the framework
  # @param capability_stable_id [String] stable UUID of the capability
  # @param level_ordinal [Integer] the level being cleared
  # @param cycle_id [String] UUID of the cycle this rating belongs to
  # @param rated_by_id [String, nil] UUID of the manager clearing the rating
  def clear_manager_rating(person_id, framework_id, capability_stable_id, level_ordinal:, cycle_id:,
                           rated_by_id: nil)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.clear_manager_rating(capability_stable_id, level_ordinal: level_ordinal, cycle_id: cycle_id,
        rated_by_id: rated_by_id)
    end
  end

  # Formally opens alignment against one role for a person's current
  # assessment cycle (ADR-22).
  #
  # Once started, self/manager ratings are frozen on the cells that role
  # reads. Issued only by the assessee's recorded reporting manager
  # (enforced by the controller-side {AssessmentPolicy#start_alignment?}).
  #
  # The aggregate additionally auto-emits an AssessmentAligned event for
  # every (capability × level) cell of the role where both perspectives
  # explicitly rated the same frequency. The conversation then focuses on
  # disagreements and unrated cells. Default-fallback agreements (where
  # one or both perspectives never recorded an explicit value) do NOT
  # auto-align — only deliberate, recorded agreement counts.
  #
  # The stream doesn't carry framework bindings, so the role's cells are
  # read here from {Assessments::RoleScope} and written onto the event.
  #
  # @param person_id [String] UUID of the person being assessed
  # @param framework_id [String] UUID of the framework
  # @param cycle_id [String] UUID of the cycle alignment is starting on
  # @param started_by_id [String] UUID of the person who started alignment
  # @param role_id [String, nil] the role aligned against; nil = the role the
  #   cycle assesses the person at
  # @param level_ordinal [Integer, nil] the level of that role the
  #   conversation is about
  # @param cell_keys [Array<Array(String, Integer)>, nil] the role's cells;
  #   read from {Assessments::RoleScope} when nil
  def start_alignment(person_id, framework_id, cycle_id, started_by_id:, role_id: nil,
                      level_ordinal: nil, cell_keys: nil)
    role_id ||= home_role_id(person_id, framework_id, cycle_id)
    cell_keys ||= Assessments::RoleScope.for(role_id: role_id, framework_id: framework_id).cells.to_a if role_id
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.start_alignment(cycle_id, started_by_id: started_by_id, role_id: role_id,
        level_ordinal: level_ordinal, cell_keys: cell_keys)
    end
  end

  # Records an agreed assessment for a capability at a specific level.
  #
  # @param person_id [String] UUID of the person
  # @param framework_id [String] UUID of the framework
  # @param capability_stable_id [String] stable UUID of the capability
  # @param level_ordinal [Integer] the level being agreed upon
  # @param aligned_frequency [String] agreed frequency
  # @param cycle_id [String] UUID of the cycle this alignment belongs to
  # @param comment [String, nil] optional comment
  # @param aligned_by_id [String, nil] UUID of the Person recording the agreement
  # @param role_id [String, nil] the role the pair is aligning against — pass
  #   it once the caller has checked the role reads the cell
  def align_assessment(person_id, framework_id, capability_stable_id,
                       level_ordinal:, aligned_frequency:, cycle_id:, comment: nil,
                       aligned_by_id: nil, role_id: nil)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.align_assessment(capability_stable_id, level_ordinal: level_ordinal,
        aligned_frequency: aligned_frequency, cycle_id: cycle_id, comment: comment,
        aligned_by_id: aligned_by_id, role_id: role_id)
    end
  end

  # Clears a previous alignment rating for a capability at a specific level.
  #
  # @param person_id [String] UUID of the person
  # @param framework_id [String] UUID of the framework
  # @param capability_stable_id [String] stable UUID of the capability
  # @param level_ordinal [Integer] the level being cleared
  # @param cycle_id [String] UUID of the cycle this alignment belongs to
  # @param cleared_by_id [String, nil] UUID of the Person clearing the alignment
  def clear_alignment_rating(person_id, framework_id, capability_stable_id,
                             level_ordinal:, cycle_id:, cleared_by_id: nil)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.clear_alignment_rating(capability_stable_id,
        level_ordinal: level_ordinal, cycle_id: cycle_id, cleared_by_id: cleared_by_id)
    end
  end

  # Marks alignment against one role complete for the current cycle.
  #
  # After this lands, that role's agreed values are the record. Issued only
  # by the assessee's recorded reporting manager (enforced by the
  # controller-side {AssessmentPolicy#complete_alignment?}).
  #
  # @param person_id [String] UUID of the person being assessed
  # @param framework_id [String] UUID of the framework
  # @param cycle_id [String] UUID of the cycle being completed
  # @param completed_by_id [String] UUID of the person completing alignment
  # @param role_id [String, nil] the role whose alignment completes; nil =
  #   the role the cycle assesses the person at
  # @param required_cell_keys [Array<Array(String, Integer)>, nil] cells that
  #   must carry an agreed value, as `[capability_stable_id, level_ordinal]`
  #   pairs — the completion coverage gate, re-checked atomically in the
  #   aggregate (see {PersonDevelopment::Aggregate#complete_alignment})
  def complete_alignment(person_id, framework_id, cycle_id, completed_by_id:, role_id: nil,
                         required_cell_keys: nil)
    role_id ||= home_role_id(person_id, framework_id, cycle_id)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.complete_alignment(cycle_id, completed_by_id: completed_by_id, role_id: role_id,
        required_cell_keys: required_cell_keys)
    end
  end

  # Re-opens a completed alignment against one role, returning it to the
  # `aligning` phase. Agreed per-cell values are preserved. Issued only by
  # the assessee's recorded reporting manager while the cycle is still open
  # (enforced by the controller-side {AssessmentPolicy#reopen_alignment?}).
  #
  # @param person_id [String] UUID of the person being assessed
  # @param framework_id [String] UUID of the framework
  # @param cycle_id [String] UUID of the cycle being re-opened
  # @param reopened_by_id [String] UUID of the person re-opening alignment
  # @param role_id [String, nil] the role whose alignment re-opens; nil =
  #   the role the cycle assesses the person at
  def reopen_alignment(person_id, framework_id, cycle_id, reopened_by_id:, role_id: nil)
    role_id ||= home_role_id(person_id, framework_id, cycle_id)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.reopen_alignment(cycle_id, reopened_by_id: reopened_by_id, role_id: role_id)
    end
  end

  # Seeds the current cycle's ratings from the prior cycle — carry-forward
  # with per-cell precedence.
  #
  # A cell the parties agreed on (aligned_frequency present) seeds BOTH
  # sides with the aligned value; a never-agreed cell seeds each
  # perspective from its own last value (self → seeded self, manager →
  # seeded manager) — the sides can start asymmetrically if one never
  # rated. All seeds are SelfRated / ManagerRated events with
  # `source: "seeded"` and `seeded_from_cycle_id: <prior>`, so the new
  # cycle opens with "this is where things stood last cycle — confirm or
  # update", whether or not that cycle's alignment completed.
  #
  # Skip-and-flag for framework version drift: only seeds capabilities
  # whose `stable_id` exists in the new cycle's framework_id (the active
  # FrameworkState projection). Skipped capabilities are returned in the
  # result hash for caller logging.
  #
  # @param person_id [String] UUID of the person being seeded
  # @param framework_id [String] UUID of the framework (current cycle)
  # @param current_cycle_id [String] UUID of the cycle being seeded INTO
  # @param prior_cycle_id [String] UUID of the cycle being seeded FROM
  # @param seeded_by_id [String] UUID of the actor (typically the HR person
  #   who triggered the new cycle's enrolment)
  # @return [Hash] :seeded count, :skipped array of {capability_stable_id, reason}
  def seed_ratings_from_prior_cycle(person_id, framework_id, current_cycle_id, prior_cycle_id,
                                     seeded_by_id:)
    # Carry-forward policy (see assessments.md → Cross-cycle seeding):
    # every prior rating seeds the new cycle, aligned or not. Per-cell
    # precedence — a cell the parties AGREED on carries the aligned value
    # into BOTH sides (shared truth, as before); a cell that was never
    # agreed carries each perspective's own last value forward, so the
    # disagreement resumes where it stopped instead of starting blank.
    # The old aligned-cycle-only gate punished a report for their
    # manager's incomplete alignment; the alternative to an imperfect
    # baseline is not a better baseline, it is blank.
    prior_rows = AssessmentLevelRating
      .across_all_roles
      .for_person(person_id)
      .for_framework(framework_id)
      .for_cycle(prior_cycle_id)
      .where(
        "aligned_frequency IS NOT NULL OR self_rated_frequency IS NOT NULL " \
        "OR manager_rated_frequency IS NOT NULL"
      )

    valid_stable_ids = FrameworkState::Capability
      .joins(:category)
      .where(framework_capability_categories: { framework_id: framework_id })
      .pluck(:stable_id)
      .to_set

    # Idempotency is PER SIDE, keyed on OWNERSHIP, not value presence: a
    # side is off-limits when it holds a value (seeded or human) OR when
    # its provenance is "human" with no value — an explicit clear (the
    # projection stamps clears as human-owned). Only a side that has
    # never held anything can be seeded on a re-run, so re-running the
    # whole seed is a no-op and never resurrects a deliberate clear.
    current_rows = AssessmentLevelRating
      .across_all_roles
      .for_person(person_id)
      .for_framework(framework_id)
      .for_cycle(current_cycle_id)
      .pluck(:capability_stable_id, :level_ordinal,
             :self_rated_frequency, :manager_rated_frequency,
             :self_rating_source, :manager_rating_source)
    self_present = current_rows.filter_map do |c, l, s, _, s_src, _|
      [ c, l ] if s.present? || s_src.present?
    end.to_set
    manager_present = current_rows.filter_map do |c, l, _, m, _, m_src|
      [ c, l ] if m.present? || m_src.present?
    end.to_set

    seeded = 0
    skipped = []

    # Load the aggregate ONCE, emit all seed + skip events inside a
    # single with_person_development block. Avoids per-event aggregate
    # replays.
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      prior_rows.each do |rating|
        stable_id = rating.capability_stable_id
        pair = [ stable_id, rating.level_ordinal ]
        self_value    = rating.aligned_frequency.presence || rating.self_rated_frequency.presence
        manager_value = rating.aligned_frequency.presence || rating.manager_rated_frequency.presence
        seed_self    = self_value.present? && !self_present.include?(pair)
        seed_manager = manager_value.present? && !manager_present.include?(pair)
        next unless seed_self || seed_manager

        unless valid_stable_ids.include?(stable_id)
          aggregate.record_seed_skip(stable_id,
            level_ordinal: rating.level_ordinal,
            prior_aligned_frequency: rating.aligned_frequency,
            current_cycle_id: current_cycle_id,
            prior_cycle_id: prior_cycle_id,
            reason: "capability_not_in_current_framework")
          skipped << {
            capability_stable_id: stable_id,
            level_ordinal: rating.level_ordinal,
            prior_aligned_frequency: rating.aligned_frequency,
            reason: "capability_not_in_current_framework"
          }
          next
        end

        if seed_self
          aggregate.rate_self(stable_id,
            level_ordinal: rating.level_ordinal,
            frequency: self_value,
            cycle_id: current_cycle_id,
            comment: "Seeded from prior cycle",
            source: "seeded",
            seeded_from_cycle_id: prior_cycle_id)
        end
        if seed_manager
          aggregate.rate_as_manager(stable_id,
            level_ordinal: rating.level_ordinal,
            frequency: manager_value,
            cycle_id: current_cycle_id,
            comment: "Seeded from prior cycle",
            source: "seeded",
            seeded_from_cycle_id: prior_cycle_id)
        end
        seeded += 1
      end
    end

    { seeded: seeded, skipped: skipped, seeded_by_id: seeded_by_id }
  end

  # Records a new piece of evidence on the person's development stream.
  #
  # The caller supplies the evidence_id (UUID v7) so the controller can
  # reference it in the response without an extra round-trip. Idempotency
  # is the caller's responsibility — re-recording with the same id raises.
  #
  # @param person_id [String] UUID of the person being evidenced
  # @param framework_id [String] UUID of the framework
  # @param evidence_id [String] caller-supplied UUID v7
  # @param capability_stable_id [String] stable UUID of the capability
  # @param level_ordinal [Integer] the level being evidenced
  # @param source [String] "self" | "manager" | "peer"
  # @param evidence_type [String] one of EvidenceItem::EVIDENCE_TYPES
  # @param content [String] body of the evidence (required)
  # @param author_id [String] UUID of the Person recording
  # @param custom_type_label [String, nil] only when evidence_type == "other"
  # @param title [String, nil] optional one-line summary
  # @param external_reference [Hash, nil] { system:, url:, external_id:, metadata: }
  # @param valence [String] the origin link's valence — one of
  #   EvidenceLink::VALENCES (required on every new link)
  # @param additional_links [Array<Hash>] extra { capability_stable_id:,
  #   level_ordinal:, valence: } links applied atomically alongside the first link
  # @param cycle_id [String, nil, Object] explicit cycle attribution, or the
  #   current aggregate cycle when omitted
  def record_evidence(person_id, framework_id, evidence_id,
                      capability_stable_id:, level_ordinal:, source:, evidence_type:,
                      content:, author_id:, valence:, custom_type_label: nil, title: nil,
                      external_reference: nil, additional_links: [], cycle_id: CURRENT_CYCLE)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      attributes = {
        capability_stable_id: capability_stable_id, level_ordinal: level_ordinal,
        source: source, evidence_type: evidence_type, content: content,
        author_id: author_id, valence: valence, custom_type_label: custom_type_label,
        feedback_direction: feedback_direction_for(source:, author_id:, person_id:),
        title: title, external_reference: external_reference,
        additional_links: additional_links
      }
      attributes[:cycle_id] = cycle_id unless cycle_id.equal?(CURRENT_CYCLE)
      aggregate.record_evidence(evidence_id, **attributes)
    end
  end

  # Links existing evidence to an additional (capability, level) coordinate.
  #
  # @param person_id [String] UUID of the person
  # @param framework_id [String] UUID of the framework
  # @param evidence_id [String] UUID of the evidence to link
  # @param capability_stable_id [String] target capability
  # @param level_ordinal [Integer] target level
  # @param linked_by_id [String] UUID of the Person adding the link
  # @param valence [String] the linker's judgment — one of EvidenceLink::VALENCES
  # @param rationale [String, nil] optional explanation
  def add_evidence_link(person_id, framework_id, evidence_id,
                        capability_stable_id:, level_ordinal:, linked_by_id:, valence:, rationale: nil)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.add_evidence_link(evidence_id,
        capability_stable_id: capability_stable_id,
        level_ordinal: level_ordinal,
        linked_by_id: linked_by_id, valence: valence, rationale: rationale)
    end
  end

  # Reclassifies an evidence link's valence (no-op when unchanged).
  #
  # @param person_id [String] UUID of the person
  # @param framework_id [String] UUID of the framework
  # @param evidence_id [String] UUID of the evidence
  # @param capability_stable_id [String] the link's capability
  # @param level_ordinal [Integer] the link's level
  # @param valence [String] one of EvidenceLink::VALENCES
  # @param changed_by_id [String] UUID of the Person reclassifying
  def set_evidence_link_valence(person_id, framework_id, evidence_id,
                                capability_stable_id:, level_ordinal:, valence:, changed_by_id:)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.set_evidence_link_valence(evidence_id,
        capability_stable_id: capability_stable_id,
        level_ordinal: level_ordinal,
        valence: valence, changed_by_id: changed_by_id)
    end
  end

  # Removes one of an evidence item's (capability, level) links.
  #
  # @param person_id [String] UUID of the person
  # @param framework_id [String] UUID of the framework
  # @param evidence_id [String] UUID of the evidence to unlink
  # @param capability_stable_id [String] the link's capability
  # @param level_ordinal [Integer] the link's level
  # @param removed_by_id [String] UUID of the Person removing the link
  # @param reason [String, nil] optional explanation
  def remove_evidence_link(person_id, framework_id, evidence_id,
                           capability_stable_id:, level_ordinal:, removed_by_id:, reason: nil)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.remove_evidence_link(evidence_id,
        capability_stable_id: capability_stable_id,
        level_ordinal: level_ordinal,
        removed_by_id: removed_by_id, reason: reason)
    end
  end

  # Edits an existing piece of evidence.
  #
  # @param person_id [String] UUID of the person being evidenced
  # @param framework_id [String] UUID of the framework
  # @param evidence_id [String] UUID of the evidence to edit
  # @param title [String, nil] post-edit title
  # @param content [String] post-edit content (required)
  # @param evidence_type [String] one of EvidenceItem::EVIDENCE_TYPES
  # @param custom_type_label [String, nil] required iff evidence_type == "other"
  # @param external_reference [Hash, nil] { system:, url:, external_id:, metadata: }
  # @param edited_by_id [String] UUID of the Person performing the edit
  def update_evidence(person_id, framework_id, evidence_id,
                      title:, content:, evidence_type:, custom_type_label:,
                      external_reference:, edited_by_id:)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.update_evidence(evidence_id,
        title: title, content: content, evidence_type: evidence_type,
        custom_type_label: custom_type_label,
        external_reference: external_reference,
        edited_by_id: edited_by_id)
    end
  end

  # Soft-deletes an evidence item.
  #
  # @param person_id [String] UUID of the person
  # @param framework_id [String] UUID of the framework
  # @param evidence_id [String] UUID of the evidence
  # @param withdrawn_by_id [String] UUID of the Person withdrawing
  # @param reason [String, nil] optional explanation
  def withdraw_evidence(person_id, framework_id, evidence_id,
                        withdrawn_by_id:, reason: nil)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.withdraw_evidence(evidence_id,
        withdrawn_by_id: withdrawn_by_id, reason: reason)
    end
  end

  # Asks a colleague for evidence about a specific (capability, level) cell.
  #
  # @param person_id [String] the assessee
  # @param framework_id [String]
  # @param request_id [String] UUID v7 minted at command time
  # @param requested_by_id [String] Person making the request
  # @param requestee_person_id [String] Person being asked
  # @param capability_stable_id [String]
  # @param level_ordinal [Integer]
  # @param message [String, nil]
  # @param due_at [String, nil]
  def request_evidence(person_id, framework_id, request_id,
                       requested_by_id:, requestee_person_id:, capability_stable_id:,
                       level_ordinal:, message: nil, due_at: nil)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.request_evidence(request_id,
        requested_by_id: requested_by_id, requestee_person_id: requestee_person_id,
        capability_stable_id: capability_stable_id, level_ordinal: level_ordinal,
        message: message, due_at: due_at)
    end
  end

  # Fulfils a pending evidence request by linking the evidence provided.
  #
  # @param evidence_id [String] the EvidenceRecorded item (source "peer")
  # @param responded_by_id [String] the requestee
  def respond_to_evidence_request(person_id, framework_id, request_id,
                                  evidence_id:, responded_by_id:)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.respond_to_evidence_request(request_id,
        evidence_id: evidence_id, responded_by_id: responded_by_id)
    end
  end

  # Declines a pending evidence request.
  #
  # @param declined_by_id [String] the requestee
  # @param reason [String, nil]
  def decline_evidence_request(person_id, framework_id, request_id,
                               declined_by_id:, reason: nil)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.decline_evidence_request(request_id,
        declined_by_id: declined_by_id, reason: reason)
    end
  end

  # Records that the requestee was nudged about a still-pending evidence
  # request — by the reminder sweep (automatic kinds, no actor) or by the
  # requester themselves (kind "manual", carrying nudged_by_id).
  #
  # @param kind [String] "no_response" | "due_soon" | "manual"
  # @param nudged_by_id [String, nil] the Person nudging (manual kind only)
  def remind_evidence_request(person_id, framework_id, request_id, kind:, nudged_by_id: nil)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.remind_evidence_request(request_id, kind: kind, nudged_by_id: nudged_by_id)
    end
  end

  # Cancels a still-pending evidence request (requester or admin).
  #
  # @param cancelled_by_id [String]
  def cancel_evidence_request(person_id, framework_id, request_id, cancelled_by_id:)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.cancel_evidence_request(request_id, cancelled_by_id: cancelled_by_id)
    end
  end

  # Posts a new comment on the person's development stream.
  #
  # Caller supplies the comment_id (UUID v7) so the controller can
  # reference it in the response without an extra round-trip.
  #
  # @param person_id [String] UUID of the person
  # @param framework_id [String] UUID of the framework
  # @param comment_id [String] caller-supplied UUID v7
  # @param commentable_type [String] "assessment_cell" (V1)
  # @param body [String] comment body
  # @param author_id [String] UUID of the Person posting
  # @param capability_stable_id [String, nil] required for both commentable types
  # @param level_ordinal [Integer, nil] required for both commentable types
  # @param evidence_id [String, nil] required for evidence_link comments
  # @param parent_id [String, nil] parent comment for threaded replies
  def post_comment(person_id, framework_id, comment_id,
                   commentable_type:, body:, author_id:,
                   capability_stable_id: nil, level_ordinal: nil,
                   evidence_id: nil, parent_id: nil)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.post_comment(comment_id,
        commentable_type: commentable_type, body: body, author_id: author_id,
        capability_stable_id: capability_stable_id, level_ordinal: level_ordinal,
        evidence_id: evidence_id, parent_id: parent_id)
    end
  end

  # Edits the body of an existing comment.
  #
  # @param person_id [String] UUID of the person
  # @param framework_id [String] UUID of the framework
  # @param comment_id [String] UUID of the comment
  # @param body [String] post-edit body
  # @param edited_by_id [String] UUID of the Person editing (must equal author)
  def edit_comment(person_id, framework_id, comment_id, body:, edited_by_id:)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.edit_comment(comment_id, body: body, edited_by_id: edited_by_id)
    end
  end

  # Soft-deletes a comment.
  #
  # @param person_id [String] UUID of the person
  # @param framework_id [String] UUID of the framework
  # @param comment_id [String] UUID of the comment
  # @param deleted_by_id [String] UUID of the Person deleting
  # @param reason [String, nil] optional explanation
  def delete_comment(person_id, framework_id, comment_id,
                     deleted_by_id:, reason: nil)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.delete_comment(comment_id,
        deleted_by_id: deleted_by_id, reason: reason)
    end
  end

  private

  # The role the cycle assesses the person at — its enrollment snapshot,
  # else the live assignment. The same home {Assessments::Lens} reads.
  #
  # @return [String, nil]
  def home_role_id(person_id, framework_id, cycle_id)
    Assessments::RoleScope.home_role_ids(cycle_id: cycle_id, framework_id: framework_id,
                                         person_ids: [ person_id ])[person_id]
  end

  def feedback_direction_for(source:, author_id:, person_id:)
    EvidenceItem.feedback_direction_for(
      source: source,
      author: Person.find_by(id: author_id),
      recipient: Person.find_by(id: person_id)
    )
  end
end
