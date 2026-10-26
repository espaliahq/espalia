# frozen_string_literal: true

# Event-sourced aggregate for a person's development journey within a framework.
#
# One RES stream per person per framework:
# tenant-{tenant_id}/PersonDev-{person_id}-{framework_id}.
#
# An "assessment" is a projection derived from this stream — not a separate entity.
# Ratings are per (capability_stable_id, level_ordinal) pair, enabling independent
# assessment of each level's behaviours. Each rating event is stamped with the
# `cycle_id` of the cycle the person was in at the time, so replay tells the
# full per-cycle story.
#
# Cycle membership is driven from the {AssessmentCycles::Aggregate} via a
# cross-stream sync handler. `join_cycle` / `leave_cycle` / `conclude_cycle`
# are called ONLY by that sync handler in response to PersonEnrolled /
# PersonUnenrolled / CycleClosed events — never by controllers.
#
class PersonDevelopment::Aggregate
  include AggregateRoot

  # Domain-specific error for command violations the controller layer
  # is expected to surface as user-facing flash alerts. Distinguishes
  # intentional command rejections from genuine programming bugs that
  # should bubble up as 500s.
  class CommandError < StandardError; end

  FREQUENCIES = %w[none some occasional consistent].freeze
  EVIDENCE_SOURCES = EvidenceItem::SOURCES
  EVIDENCE_TYPES = EvidenceItem::EVIDENCE_TYPES
  EVIDENCE_DIRECTIONS_BY_SOURCE = {
    "self" => %w[self],
    "manager" => %w[manager_to_report],
    "peer" => %w[peer_to_peer report_to_manager]
  }.freeze
  EVIDENCE_VALENCES = EvidenceLink::VALENCES
  EVIDENCE_REQUEST_REMINDER_KINDS = %w[no_response due_soon manual].freeze
  EVIDENCE_REQUEST_NUDGE_GAP = EvidenceRequest::NUDGE_GAP
  # What came of a declared exploration: work towards it, set it aside, or
  # the person has moved into the role.
  EXPLORATION_OUTCOMES = %w[pursue not_now moved].freeze

  def initialize
    @person_id = nil
    @framework_id = nil
    @role_id = nil
    @level_id = nil
    @assigned = false
    @manager_id = nil       # recorded reporting manager (authoritative for rating authority)
    @active_delegates = {}   # delegate person id => expires_at (nil = open-ended)
    @current_cycle_id = nil
    # The role the current cycle assesses the person at — the role they held
    # when they joined it. A historical alignment event carries no role and
    # belongs to this one.
    @home_role_id = nil
    # Per-role alignment within the current cycle (ADR-22):
    #   role_id => { completed: Boolean, cells: Set<[stable_id, level_ordinal]> | :all }
    # `:all` is a start with no cell list — every event before per-role
    # alignment — and freezes the whole assessment, as those always did.
    @alignments = {}
    @self_ratings = {}    # [stable_id, level_ordinal] => frequency
    @manager_ratings = {} # [stable_id, level_ordinal] => frequency
    # Per-cell provenance ("human" | "seeded"; nil for pre-provenance
    # history = human). Auto-align reads these: only VETTED agreements
    # formalise at alignment start.
    @self_rating_sources = {}
    @manager_rating_sources = {}
    @aligned_ratings = {} # [stable_id, level_ordinal] => frequency
    @evidence = {}       # evidence_id => { links: { [capability_stable_id, level_ordinal] => valence, ... }, ever_linked: Set, status: }
    @evidence_requests = {} # request_id => { status:, requestee_person_id:, capability_stable_id:, level_ordinal: }
    @comments = {}       # comment_id => { commentable_type:, capability_stable_id:, level_ordinal:, evidence_id:, parent_id:, author_id:, status: }
    @last_migrated_to_version = nil # highest framework version this stream has been migrated to
    @assessed_framework_version = nil # framework version the CURRENT cycle is assessed against
    # Declared explorations (ADR-22) — intent facts that outlive cycles:
    #   exploration_id => { target_role_id:, target_level_id:, open: Boolean }
    @explorations = {}
  end

  # ── Assignment ──

  # Assigns a person to a framework with a specific role and level.
  #
  # @param person_id [String] UUID of the person
  # @param framework_id [String] UUID of the framework
  # @param role_id [String] UUID of the assigned role
  # @param level_id [String] UUID of the assigned level
  # @param assigned_by [String, nil] UUID of the Person who triggered the
  #   assignment; nil for system-driven HRIS syncs
  # @raise [RuntimeError] if already assigned
  def assign_to_framework(person_id, framework_id, role_id, level_id, assigned_by: nil)
    raise "Person already assigned to this framework" if @assigned

    apply(PersonDevelopment::Events::PersonAssignedToFramework.new(data: {
      person_id: person_id,
      framework_id: framework_id,
      role_id: role_id,
      level_id: level_id,
      assigned_by: assigned_by
    }))
  end

  # Changes a person's role (and level) within their current framework.
  #
  # Used for transfers — any role change implies a new level because
  # level_ids are scoped to roles.
  #
  # @param new_role_id [String] UUID of the new role
  # @param new_level_id [String] UUID of the new level (must belong to new role)
  # @param reason [String] why the change occurred (e.g. "hris_sync", "manual")
  # @param changed_by [String, nil] UUID of the Person who triggered the change;
  #   nil for system-driven HRIS syncs
  # @raise [RuntimeError] if not yet assigned, or if role is unchanged
  def change_role(new_role_id, new_level_id, reason: "hris_sync", changed_by: nil)
    ensure_assigned!
    raise "Role unchanged" if @role_id == new_role_id

    apply(PersonDevelopment::Events::PersonRoleChanged.new(data: {
      previous_role_id: @role_id,
      new_role_id: new_role_id,
      previous_level_id: @level_id,
      new_level_id: new_level_id,
      reason: reason,
      changed_by: changed_by
    }))
    close_explorations_moved_into(changed_by)
  end

  # Changes a person's level within the same role (promotion).
  #
  # @param new_level_id [String] UUID of the new level (must belong to current role)
  # @param reason [String] why the change occurred (e.g. "hris_sync", "manual")
  # @param changed_by [String, nil] UUID of the Person who triggered the change;
  #   nil for system-driven HRIS syncs
  # @raise [RuntimeError] if not yet assigned, or if level is unchanged
  def change_level(new_level_id, reason: "hris_sync", changed_by: nil)
    ensure_assigned!
    raise "Level unchanged" if @level_id == new_level_id

    apply(PersonDevelopment::Events::PersonLevelChanged.new(data: {
      previous_level_id: @level_id,
      new_level_id: new_level_id,
      reason: reason,
      changed_by: changed_by
    }))
    close_explorations_moved_into(changed_by)
  end

  # Removes the person's framework assignment entirely — the exit from the
  # assign → change_role → change_level lifecycle. Used when the person's real
  # role no longer maps to any framework role, or to correct an erroneous
  # assignment. The PersonUnassignedFromFramework event preserves the full
  # history; only the read-model row is removed, and the person may be
  # re-assigned later (the {#assign_to_framework} guard keys off `@assigned`).
  #
  # Blocked while the person is enrolled in an open cycle: cycle membership is
  # manager-driven (see {AssessmentCycles::Aggregate}), so the caller must
  # unenroll first rather than have an unassign silently orphan in-flight
  # rating/evidence work. This keeps the cross-stream effect explicit.
  #
  # @param reason [String] why the assignment was removed (e.g. "manual",
  #   "role_unmapped", "data_correction")
  # @param unassigned_by [String, nil] UUID of the Person who triggered it;
  #   nil for system-driven actions
  # @raise [RuntimeError] if not assigned, or if still enrolled in a cycle
  def unassign_from_framework(reason: "manual", unassigned_by: nil)
    ensure_assigned!
    unless @current_cycle_id.nil?
      raise "Cannot unassign while enrolled in a cycle; leave the cycle first"
    end

    apply(PersonDevelopment::Events::PersonUnassignedFromFramework.new(data: {
      previous_role_id: @role_id,
      previous_level_id: @level_id,
      reason: reason,
      unassigned_by: unassigned_by
    }))
  end

  # ── Reporting manager ──

  # Records the person's reporting manager as a first-class domain fact.
  #
  # Idempotent: a no-op when the manager already matches the recorded value, so
  # re-running HRIS sync emits nothing. Populated from HRIS sync and a one-off
  # backfill; the recorded value is authoritative for the manager-rating
  # invariant (see {#rate_as_manager}) and for {AssessmentPolicy}.
  #
  # @param manager_id [String, nil] UUID of the reporting manager (skipped when nil)
  # @param source [String] "hris" or "backfill"
  def record_reporting_manager(manager_id, source: "hris")
    return if manager_id.nil?
    return if manager_id == @manager_id

    apply(PersonDevelopment::Events::ReportingManagerRecorded.new(data: {
      manager_id: manager_id,
      previous_manager_id: @manager_id,
      source: source
    }))
  end

  # ── Manager-rating delegation ──

  # Grants manager-rating authority for this person/framework to another person.
  #
  # Does not require an open cycle — a delegation can be set up ahead of a cycle
  # and persists across cycles until revoked/expired. Idempotent when the person
  # already holds an active delegation. Granter authority (ancestor manager or
  # tenant admin) is enforced by the controller-side policy, not the aggregate.
  #
  # @param delegate_person_id [String] UUID of the person receiving authority
  # @param granted_by_id [String] UUID of the granter
  # @param expires_at [String, Time, nil] optional expiry
  # @param reason [String, nil] optional note
  # @raise [CommandError] if delegating to the assessee or to nobody
  def delegate_manager_rating(delegate_person_id, granted_by_id:, expires_at: nil, reason: nil)
    raise CommandError, "Delegate is required" if delegate_person_id.blank?
    raise CommandError, "Cannot delegate to the assessee" if delegate_person_id == @person_id
    # Idempotent only against a still-active grant — an expired delegation can be
    # renewed (a fresh event with a new expires_at).
    return if delegate_active?(delegate_person_id)

    apply(PersonDevelopment::Events::ManagerRatingDelegated.new(data: {
      delegate_person_id: delegate_person_id,
      granted_by_id: granted_by_id,
      expires_at: expires_at,
      reason: reason
    }))
  end

  # Revokes a manager-rating delegation. Non-destructive — existing ratings the
  # delegate made remain, attributed to them.
  #
  # @param delegate_person_id [String] UUID of the delegate
  # @param revoked_by_id [String] UUID of the revoker
  # @raise [CommandError] if no active delegation exists for the delegate
  def revoke_manager_rating_delegation(delegate_person_id, revoked_by_id:)
    raise CommandError, "No active delegation for this person" unless
      @active_delegates.key?(delegate_person_id)

    apply(PersonDevelopment::Events::ManagerRatingDelegationRevoked.new(data: {
      delegate_person_id: delegate_person_id,
      revoked_by_id: revoked_by_id
    }))
  end

  # ── Calibration revisit requests ──

  # Records a calibration session's value-free ask that the rater revisit
  # one of their manager ratings on this stream — the PD-side mirror,
  # invoked ONLY by {AssessmentCycles::SyncHandlers::CalibrationRevisitSync}.
  #
  # No lifecycle state is tracked: resolution is rating-change-based and
  # computed at read time (a manager rating recorded for the cell after the
  # request settles every open request against it at once), so requests
  # from any number of overlapping sessions compose without contradiction.
  #
  # @param capability_stable_id [String]
  # @param level_ordinal [Integer]
  # @param calibration_session_id [String] provenance — the asking session
  # @param rater_id [String] person_id of the rater being asked
  # @param note [String] the room's discussion note
  # @param session_name [String, nil] display name at event time
  # @param requested_by_id [String, nil] the facilitator
  # @raise [CommandError] if the person isn't assigned or the note is blank
  def request_rating_revisit(capability_stable_id:, level_ordinal:, calibration_session_id:,
                             rater_id:, note:, session_name: nil, requested_by_id: nil)
    ensure_assigned!
    raise CommandError, "Revisit note cannot be blank" if note.to_s.strip.empty?

    apply(PersonDevelopment::Events::RatingRevisitRequested.new(data: {
      capability_stable_id: capability_stable_id,
      level_ordinal: level_ordinal,
      calibration_session_id: calibration_session_id,
      session_name: session_name,
      rater_id: rater_id,
      note: note,
      requested_by_id: requested_by_id
    }.compact))
  end

  # ── Declared explorations ──
  #
  # "We've agreed to explore this" (ADR-22): an intent fact about another
  # role or level, visible to both parties, with a lifecycle. Not a rating
  # scope — the lens reads the same ratings — so it needs an assignment but
  # no open cycle, and survives from one cycle to the next. Who may declare
  # or close (the assessee, their reporting manager, an active rating
  # delegate) is the controller-side policy's call.

  # Declares an exploration of another role or level.
  #
  # @param exploration_id [String] caller-minted UUID v7
  # @param target_role_id [String]
  # @param target_level_id [String] a level of the target role
  # @param target_level_ordinal [Integer] that level's ordinal
  # @param started_by_id [String, nil] UUID of the Person declaring it
  # @param note [String, nil]
  # @raise [CommandError] if not assigned, the id is taken, the target is the
  #   role and level the person holds, or an exploration of the role is open
  def start_exploration(exploration_id, target_role_id:, target_level_id:, target_level_ordinal:,
                        started_by_id:, note: nil)
    raise CommandError, "Not assigned to this framework" unless @assigned
    raise CommandError, "Exploration id is required" if exploration_id.blank?
    raise CommandError, "A target role and level are required" if target_role_id.blank? || target_level_id.blank?
    raise CommandError, "Exploration #{exploration_id} already exists" if @explorations.key?(exploration_id)
    raise CommandError, "That is the role and level already held" if
      target_role_id == @role_id && target_level_id == @level_id
    raise CommandError, "An exploration of that role is already open" if
      @explorations.each_value.any? { |state| state[:open] && state[:target_role_id] == target_role_id }

    apply(PersonDevelopment::Events::ExplorationStarted.new(data: {
      exploration_id: exploration_id,
      target_role_id: target_role_id,
      target_level_id: target_level_id,
      target_level_ordinal: target_level_ordinal,
      started_by_id: started_by_id,
      note: note.presence
    }))
  end

  # Closes an open exploration with what came of it.
  #
  # @param exploration_id [String]
  # @param closed_by_id [String, nil] UUID of the Person closing it
  # @param outcome [String] one of EXPLORATION_OUTCOMES
  # @param note [String, nil]
  # @raise [CommandError] if the exploration is unknown or already closed, or
  #   the outcome is invalid
  def close_exploration(exploration_id, closed_by_id:, outcome:, note: nil)
    state = @explorations[exploration_id]
    raise CommandError, "No exploration with id #{exploration_id}" unless state
    raise CommandError, "That exploration is already closed" unless state[:open]
    raise CommandError, "Invalid outcome: #{outcome}" unless EXPLORATION_OUTCOMES.include?(outcome)

    apply(PersonDevelopment::Events::ExplorationClosed.new(data: {
      exploration_id: exploration_id,
      closed_by_id: closed_by_id,
      outcome: outcome,
      note: note.presence
    }))
  end

  # ── Assessment Cycle Membership ──
  #
  # These commands are invoked ONLY by
  # {AssessmentCycles::SyncHandlers::PersonEnrollmentSync}, never by user code.

  # Migrates the person's stream onto a new framework version.
  #
  # Called by {Frameworks::SyncHandlers::FrameworkVersionMigrationSync}
  # in the same transaction as the originating
  # {Frameworks::Events::FrameworkVersionPublished}. Self-describing —
  # the mappings payload is everything the projections need.
  #
  # Idempotent: if this stream has already been migrated to a version
  # at or beyond `new_version` (e.g. during predeploy replay), the
  # command silently no-ops rather than emitting a duplicate event.
  #
  # @param framework_id [String] UUID of the framework being republished
  # @param old_version [Integer] previous published version
  # @param new_version [Integer] newly published version
  # @param mappings [Array<Hash>] one entry per archived capability
  #   (see {PersonDevelopment::Events::FrameworkVersionMigrated} for shape)
  # @raise [RuntimeError] if not assigned to this framework, or if the current
  #   cycle's alignment is already completed (a completed assessment is an
  #   immutable record and must not be migrated — see the freeze-vs-migrate
  #   decision; the dispatching sync handler skips such participants so this
  #   guard is defense-in-depth rather than the primary gate)
  def migrate_framework_version(framework_id, old_version, new_version, mappings)
    ensure_assigned!
    raise "Framework_id #{framework_id} does not match assignment" unless @framework_id == framework_id
    return if @last_migrated_to_version && @last_migrated_to_version >= new_version
    raise "Cannot migrate a completed assessment cycle" if home_alignment_completed?

    apply(PersonDevelopment::Events::FrameworkVersionMigrated.new(data: {
      framework_id: framework_id,
      old_version: old_version,
      new_version: new_version,
      mappings: mappings
    }))
  end

  # Joins the given assessment cycle.
  #
  # @param cycle_id [String] UUID of the cycle to join
  # @param framework_version [Integer] framework version the cycle assesses against
  # @raise [RuntimeError] if not assigned or already in a cycle
  def join_cycle(cycle_id, framework_version)
    ensure_assigned!
    raise "Already in a cycle" unless @current_cycle_id.nil?

    apply(PersonDevelopment::Events::JoinedAssessmentCycle.new(data: {
      cycle_id: cycle_id,
      framework_version: framework_version
    }))
  end

  # Leaves the given assessment cycle — a person-scoped removal (opted out,
  # left the company, enrolled by mistake). A cycle closing around the
  # person is NOT a leave; that path is {#conclude_cycle}, and the legacy
  # "cycle_closed" reason is rejected so a stale caller can't misclassify a
  # normal closure as a withdrawal.
  #
  # @param cycle_id [String] UUID of the cycle being left (must match current)
  # @param reason [String] why the person is leaving (e.g. "withdrew")
  # @raise [RuntimeError] if not in a cycle, cycle_id doesn't match, or the
  #   reason is "cycle_closed"
  def leave_cycle(cycle_id, reason)
    # Internal backstop only — AssessmentCycles::Aggregate#unenroll already
    # rejects the reserved reason at the user-facing boundary, so this can
    # only fire for a stale in-code caller still wiring closure to leave.
    raise "Use conclude_cycle for cycle closure" if reason.to_s == "cycle_closed"
    ensure_in_cycle!(cycle_id)

    apply(PersonDevelopment::Events::LeftAssessmentCycle.new(data: {
      cycle_id: cycle_id,
      reason: reason
    }))
  end

  # Concludes the given assessment cycle for this person.
  #
  # Distinct from {#leave_cycle}: the person is not being removed — the
  # cycle is ending around them. Their participation stands as part of the
  # cycle's cohort; an unrated enrollment still concludes.
  #
  # @param cycle_id [String] UUID of the cycle concluding (must match current)
  # @raise [RuntimeError] if not in a cycle or cycle_id doesn't match
  def conclude_cycle(cycle_id)
    ensure_in_cycle!(cycle_id)

    apply(PersonDevelopment::Events::AssessmentCycleConcluded.new(data: {
      cycle_id: cycle_id
    }))
  end

  # ── Self-Rating ──

  # Records a self-rating for a capability at a specific level.
  #
  # @param capability_stable_id [String] stable UUID of the capability
  # @param level_ordinal [Integer] the level being assessed
  # @param frequency [String] "some", "occasional", or "consistent"
  # @param cycle_id [String] UUID of the cycle this rating belongs to
  # @param comment [String, nil] optional rationale
  # @raise [RuntimeError] if not in a cycle, wrong cycle, or invalid frequency
  def rate_self(capability_stable_id, level_ordinal:, frequency:, cycle_id:, comment: nil,
                source: "human", seeded_from_cycle_id: nil, via_role_id: nil)
    ensure_in_cycle!(cycle_id)
    ensure_individual_ratings_unfrozen!(capability_stable_id, level_ordinal)
    raise "Invalid frequency: #{frequency}" unless FREQUENCIES.include?(frequency)

    apply(PersonDevelopment::Events::SelfRated.new(data: {
      capability_stable_id: capability_stable_id,
      level_ordinal: level_ordinal,
      frequency: frequency,
      cycle_id: cycle_id,
      comment: comment,
      source: source,
      seeded_from_cycle_id: seeded_from_cycle_id,
      via_role_id: via_role_id
    }))
  end

  # Revises a previous self-rating at a specific level.
  #
  # @param capability_stable_id [String] stable UUID of the capability
  # @param level_ordinal [Integer] the level being revised
  # @param frequency [String] revised frequency
  # @param rationale [String] reason for the change
  # @param cycle_id [String] UUID of the cycle this rating belongs to
  # @param comment [String, nil] optional comment
  # @raise [RuntimeError] if no prior self-rating for this capability at this level
  def revise_self_rating(capability_stable_id, level_ordinal:, frequency:, rationale:, cycle_id:, comment: nil,
                         via_role_id: nil)
    ensure_in_cycle!(cycle_id)
    ensure_individual_ratings_unfrozen!(capability_stable_id, level_ordinal)
    raise "Invalid frequency: #{frequency}" unless FREQUENCIES.include?(frequency)
    raise "No self-rating exists for capability #{capability_stable_id} at level #{level_ordinal}" unless
      @self_ratings.key?([ capability_stable_id, level_ordinal ])

    apply(PersonDevelopment::Events::SelfRatingRevised.new(data: {
      capability_stable_id: capability_stable_id,
      level_ordinal: level_ordinal,
      frequency: frequency,
      cycle_id: cycle_id,
      comment: comment,
      rationale: rationale,
      via_role_id: via_role_id
    }))
  end

  # Clears a previous self-rating at a specific level.
  #
  # @param capability_stable_id [String] stable UUID of the capability
  # @param level_ordinal [Integer] the level being cleared
  # @param cycle_id [String] UUID of the cycle this rating belongs to
  # @raise [RuntimeError] if no prior self-rating for this capability at this level
  def clear_self_rating(capability_stable_id, level_ordinal:, cycle_id:)
    ensure_in_cycle!(cycle_id)
    ensure_individual_ratings_unfrozen!(capability_stable_id, level_ordinal)
    raise "No self-rating exists for capability #{capability_stable_id} at level #{level_ordinal}" unless
      @self_ratings.key?([ capability_stable_id, level_ordinal ])

    apply(PersonDevelopment::Events::SelfRatingCleared.new(data: {
      capability_stable_id: capability_stable_id,
      level_ordinal: level_ordinal,
      cycle_id: cycle_id
    }))
  end

  # ── Manager Rating ──

  # Records a manager's rating for a person's capability at a specific level.
  #
  # @param capability_stable_id [String] stable UUID of the capability
  # @param level_ordinal [Integer] the level being assessed
  # @param frequency [String] "some", "occasional", or "consistent"
  # @param cycle_id [String] UUID of the cycle this rating belongs to
  # @param comment [String, nil] optional rationale
  # @param rated_by_id [String, nil] UUID of the manager recording the rating;
  #   nil for system "seeded" carry-forwards
  # @raise [RuntimeError] if not in a cycle, wrong cycle, or invalid frequency
  def rate_as_manager(capability_stable_id, level_ordinal:, frequency:, cycle_id:, comment: nil,
                      source: "human", seeded_from_cycle_id: nil, rated_by_id: nil, via_role_id: nil)
    ensure_in_cycle!(cycle_id)
    ensure_individual_ratings_unfrozen!(capability_stable_id, level_ordinal)
    ensure_manager_authority!(rated_by_id, source)
    raise "Invalid frequency: #{frequency}" unless FREQUENCIES.include?(frequency)

    apply(PersonDevelopment::Events::ManagerRated.new(data: {
      capability_stable_id: capability_stable_id,
      level_ordinal: level_ordinal,
      frequency: frequency,
      cycle_id: cycle_id,
      comment: comment,
      source: source,
      seeded_from_cycle_id: seeded_from_cycle_id,
      rated_by_id: rated_by_id,
      via_delegation: rated_via_delegation?(rated_by_id),
      via_role_id: via_role_id
    }))
  end

  # Revises a previous manager rating at a specific level.
  #
  # @param capability_stable_id [String] stable UUID of the capability
  # @param level_ordinal [Integer] the level being revised
  # @param frequency [String] revised frequency
  # @param rationale [String] reason for the change
  # @param cycle_id [String] UUID of the cycle this rating belongs to
  # @param comment [String, nil] optional comment
  # @param rated_by_id [String, nil] UUID of the manager recording the revision
  # @raise [RuntimeError] if no prior manager rating for this capability at this level
  def revise_manager_rating(capability_stable_id, level_ordinal:, frequency:, rationale:, cycle_id:, comment: nil,
                            rated_by_id: nil, via_role_id: nil)
    ensure_in_cycle!(cycle_id)
    ensure_individual_ratings_unfrozen!(capability_stable_id, level_ordinal)
    ensure_manager_authority!(rated_by_id, "human")
    raise "Invalid frequency: #{frequency}" unless FREQUENCIES.include?(frequency)
    raise "No manager rating exists for capability #{capability_stable_id} at level #{level_ordinal}" unless
      @manager_ratings.key?([ capability_stable_id, level_ordinal ])

    apply(PersonDevelopment::Events::ManagerRatingRevised.new(data: {
      capability_stable_id: capability_stable_id,
      level_ordinal: level_ordinal,
      frequency: frequency,
      cycle_id: cycle_id,
      comment: comment,
      rationale: rationale,
      rated_by_id: rated_by_id,
      via_delegation: rated_via_delegation?(rated_by_id),
      via_role_id: via_role_id
    }))
  end

  # Clears a previous manager rating at a specific level.
  #
  # @param capability_stable_id [String] stable UUID of the capability
  # @param level_ordinal [Integer] the level being cleared
  # @param cycle_id [String] UUID of the cycle this rating belongs to
  # @param rated_by_id [String, nil] UUID of the manager clearing the rating
  # @raise [RuntimeError] if no prior manager rating for this capability at this level
  def clear_manager_rating(capability_stable_id, level_ordinal:, cycle_id:, rated_by_id: nil)
    ensure_in_cycle!(cycle_id)
    ensure_individual_ratings_unfrozen!(capability_stable_id, level_ordinal)
    ensure_manager_authority!(rated_by_id, "human")
    raise "No manager rating exists for capability #{capability_stable_id} at level #{level_ordinal}" unless
      @manager_ratings.key?([ capability_stable_id, level_ordinal ])

    apply(PersonDevelopment::Events::ManagerRatingCleared.new(data: {
      capability_stable_id: capability_stable_id,
      level_ordinal: level_ordinal,
      cycle_id: cycle_id,
      rated_by_id: rated_by_id,
      via_delegation: rated_via_delegation?(rated_by_id)
    }))
  end

  # ── Alignment ──

  # Formally opens alignment against one role for the current cycle.
  #
  # Alignment is per role (ADR-22): the home role's alignment is the
  # record's, and a manager can also start one against another role the
  # person is being read against. Once started, self and manager ratings are
  # frozen on the cells that role reads — a cell is frozen once ANY started
  # role reads it, so starting PM3 freezes the cells E3 shares with it while
  # E3-only cells stay editable. Issued by the assessee's recorded reporting
  # manager (enforced by the controller-side policy, not the aggregate).
  #
  # Cells where self and manager already agree — explicitly, this cycle —
  # align automatically, within the role's cells only.
  #
  # @param cycle_id [String] UUID of the cycle alignment is starting on
  # @param started_by_id [String] UUID of the person who started alignment
  # @param role_id [String, nil] the role aligned against; nil = the role the
  #   cycle assesses the person at
  # @param cell_keys [Array<Array(String, Integer)>, nil] the role's cells as
  #   `[capability_stable_id, level_ordinal]` pairs — the stream doesn't carry
  #   framework bindings, so the caller supplies them, as it supplies
  #   `required_cell_keys` to {#complete_alignment}. nil covers every cell:
  #   the contract every event before per-role alignment carries. The command
  #   handler always passes the role's scope.
  # @param level_ordinal [Integer, nil] the level of that role the
  #   conversation is about — the one its completion gate counts
  # @raise [RuntimeError] if not in a cycle, wrong cycle, or already started
  #   against this role
  def start_alignment(cycle_id, started_by_id:, role_id: nil, cell_keys: nil, level_ordinal: nil)
    ensure_in_cycle!(cycle_id)
    role_id ||= @home_role_id
    raise "Alignment already started for this cycle" if @alignments.key?(role_id)

    cells = cell_keys&.map { |stable_id, ordinal| [ stable_id, ordinal ] }
    apply(PersonDevelopment::Events::AlignmentStarted.new(data: {
      cycle_id: cycle_id,
      started_by_id: started_by_id,
      role_id: role_id,
      level_ordinal: level_ordinal,
      cell_keys: cells
    }))

    # Auto-align cells where self and manager explicitly recorded the same
    # frequency. Derived from the aggregate's own state (`@self_ratings`
    # and `@manager_ratings`) so we're guaranteed consistent with the
    # event stream this aggregate was loaded from — unlike a read-model
    # query, which can race with concurrent rate_* commits.
    #
    # Only the role's own cells, and only cells not already agreed — a
    # second role's start must not rewrite the first conversation's
    # outcome.
    #
    # VETTED agreements only: a carried-forward (seeded) side is not
    # deliberate agreement this cycle — ADR-20 seeds both sides of a
    # previously-agreed cell with equal values, so without the provenance
    # check, starting alignment would instantly formalise every unvetted
    # carried cell. Those cells stay open for the alignment conversation
    # instead (aligning one there IS the vetting). nil source = human
    # (pre-provenance history).
    covered = @alignments.fetch(role_id)
    @self_ratings.each do |key, self_freq|
      manager_freq = @manager_ratings[key]
      next unless manager_freq == self_freq
      next unless covers?(covered, key)
      next if @aligned_ratings.key?(key)
      next if @self_rating_sources[key] == "seeded" || @manager_rating_sources[key] == "seeded"

      capability_stable_id, level_ordinal = key
      apply(PersonDevelopment::Events::AssessmentAligned.new(data: {
        capability_stable_id: capability_stable_id,
        level_ordinal: level_ordinal,
        aligned_frequency: self_freq,
        cycle_id: cycle_id,
        comment: "Auto-aligned: self and manager already agreed",
        aligned_by_id: started_by_id
      }))
    end
  end

  # Records an agreed assessment for a capability at a specific level.
  #
  # Requires an alignment in progress against a role that reads the cell.
  # The aligned_frequency is the authoritative view used in scoring. Agreed
  # level is derived as the highest level_ordinal where
  # aligned_frequency == "consistent".
  #
  # @param capability_stable_id [String] stable UUID of the capability
  # @param level_ordinal [Integer] the level being agreed upon
  # @param aligned_frequency [String] agreed frequency
  # @param cycle_id [String] UUID of the cycle this alignment belongs to
  # @param comment [String, nil] optional comment
  # @param aligned_by_id [String, nil] UUID of the Person recording the agreement
  # @param role_id [String, nil] the role the pair is aligning against, when
  #   the caller knows it reads the cell. A cell that role gained after its
  #   alignment started (a framework publish mid-conversation) joins the
  #   role's cells here — without it, the completion gate would count a cell
  #   nobody could agree.
  # @raise [RuntimeError] if not in a cycle, wrong cycle, the cell isn't in
  #   an alignment in progress, or invalid frequency
  def align_assessment(capability_stable_id, level_ordinal:, aligned_frequency:, cycle_id:, comment: nil,
                       aligned_by_id: nil, role_id: nil)
    ensure_in_cycle!(cycle_id)
    ensure_alignable!([ capability_stable_id, level_ordinal ], role_id: role_id)
    raise "Invalid frequency: #{aligned_frequency}" unless FREQUENCIES.include?(aligned_frequency)

    apply(PersonDevelopment::Events::AssessmentAligned.new(data: {
      capability_stable_id: capability_stable_id,
      level_ordinal: level_ordinal,
      aligned_frequency: aligned_frequency,
      cycle_id: cycle_id,
      comment: comment,
      aligned_by_id: aligned_by_id,
      role_id: role_id
    }))
  end

  # Clears a previous alignment rating at a specific level.
  #
  # Symmetric counterpart to {#clear_self_rating} / {#clear_manager_rating}.
  # During the alignment phase, either party can undo an alignment they
  # set by re-clicking the same value in the inline pill — the
  # controller treats a "post the same frequency back" submission as a
  # clear. Refuses once the cell's alignment has been completed.
  #
  # @param capability_stable_id [String] stable UUID of the capability
  # @param level_ordinal [Integer] the level being cleared
  # @param cycle_id [String] UUID of the cycle this alignment belongs to
  # @param cleared_by_id [String, nil] UUID of the Person clearing the alignment
  # @raise [RuntimeError] if not in a cycle, wrong cycle, the cell isn't in
  #   an alignment in progress, or no prior alignment for this cell
  def clear_alignment_rating(capability_stable_id, level_ordinal:, cycle_id:, cleared_by_id: nil)
    ensure_in_cycle!(cycle_id)
    ensure_alignable!([ capability_stable_id, level_ordinal ])
    raise "No alignment exists for capability #{capability_stable_id} at level #{level_ordinal}" unless
      @aligned_ratings.key?([ capability_stable_id, level_ordinal ])

    apply(PersonDevelopment::Events::AlignmentCleared.new(data: {
      capability_stable_id: capability_stable_id,
      level_ordinal: level_ordinal,
      cycle_id: cycle_id,
      cleared_by_id: cleared_by_id
    }))
  end

  # Records that a single capability was skipped during seed-from-prior-cycle
  # because its stable_id is no longer present in the current framework
  # version. Audit-only — no aggregate state changes; the event lands on
  # the person-development stream for later migration tooling to replay.
  #
  # Always called from inside seed_ratings_from_prior_cycle (same
  # with_person_development block as the SelfRated/ManagerRated seed
  # events) — does not require the cycle to be open or any other state.
  #
  # @param capability_stable_id [String] stable UUID of the prior capability
  # @param level_ordinal [Integer] level the prior aligned value sat at
  # @param prior_aligned_frequency [String] frequency that would have been seeded
  # @param current_cycle_id [String] UUID of the cycle being seeded into
  # @param prior_cycle_id [String] UUID of the cycle the value came from
  # @param reason [String] machine-friendly reason
  def record_seed_skip(capability_stable_id, level_ordinal:, prior_aligned_frequency:,
                       current_cycle_id:, prior_cycle_id:, reason:)
    apply(PersonDevelopment::Events::RatingSeedSkipped.new(data: {
      capability_stable_id: capability_stable_id,
      level_ordinal: level_ordinal,
      prior_aligned_frequency: prior_aligned_frequency,
      current_cycle_id: current_cycle_id,
      prior_cycle_id: prior_cycle_id,
      reason: reason
    }))
  end

  # Marks alignment against one role complete for the current cycle.
  #
  # After this lands, the agreed values on that role's cells are the record
  # of the conversation and stay frozen. Completion is per role: E3's gate
  # never counts PM3's cells and vice versa. Issued by the assessee's
  # recorded reporting manager (enforced by the controller-side
  # {AssessmentPolicy#complete_alignment?}).
  #
  # Snapshot point — long streams compress here.
  #
  # @param cycle_id [String] UUID of the cycle being completed
  # @param completed_by_id [String] UUID of the person completing alignment
  # @param role_id [String, nil] the role whose alignment completes; nil =
  #   the role the cycle assesses the person at
  # @param required_cell_keys [Array<Array(String, Integer)>, nil] cells that
  #   MUST carry an agreed value for completion to proceed, as
  #   `[capability_stable_id, level_ordinal]` pairs. The caller supplies the
  #   denominator (framework structure isn't on this stream), but checking it
  #   HERE makes the coverage gate atomic: the check runs against the
  #   aggregate's replayed state, serialized with any concurrent align/clear
  #   on the same stream — closing the gap between a read-model coverage
  #   check at the edge and this command landing. Nil skips the check
  #   (trusted internal callers, pre-gate history).
  #   (No framework-version binding on the key list: a mid-flight
  #   `FrameworkVersionMigrated` could in principle stale the denominator,
  #   but pinning to the cycle's rolled version would falsely lock out
  #   post-roll joiners, whose streams legitimately sit at the enrollment's
  #   define-time version — see PersonEnrolled's `framework_version`. The
  #   publish-vs-complete race is a deliberate, rare admin action in a
  #   millisecond window; it stays in the documented known-limitation class
  #   of `FrameworkVersionMigrated` coverage staleness.)
  # @raise [RuntimeError] if not in a cycle, wrong cycle, alignment not
  #   started against the role, already completed, or a required cell lacks
  #   an agreed value
  def complete_alignment(cycle_id, completed_by_id:, role_id: nil, required_cell_keys: nil)
    ensure_in_cycle!(cycle_id)
    role_id ||= @home_role_id
    alignment = @alignments[role_id]
    raise "Alignment has not been started for this cycle" unless alignment
    raise "Alignment already completed for this cycle" if alignment[:completed]

    missing = Array(required_cell_keys).reject { |key| @aligned_ratings.key?(key) }
    if missing.any?
      raise "#{missing.size} current-level #{missing.size == 1 ? 'cell lacks' : 'cells lack'} " \
            "an agreed rating"
    end

    apply(PersonDevelopment::Events::FullAlignmentCompleted.new(data: {
      cycle_id: cycle_id,
      completed_by_id: completed_by_id,
      framework_version: @assessed_framework_version,
      role_id: role_id
    }))
  end

  # Re-opens a completed alignment against one role, returning it to the
  # `aligning` phase so a manager can correct a completion made by accident.
  #
  # The agreed (aligned) per-cell values are PRESERVED — re-opening only
  # lifts the completion freeze; it does not clear or re-derive any
  # alignment. The manager resumes editing agreed values and re-completes
  # via {#complete_alignment} (which re-stamps the milestone; auto-align is
  # a start-time behaviour and is NOT re-run). Issued by the assessee's
  # recorded reporting manager while the cycle is still open (enforced by
  # the controller-side {AssessmentPolicy#reopen_alignment?}).
  #
  # @param cycle_id [String] UUID of the cycle being re-opened
  # @param reopened_by_id [String] UUID of the person re-opening alignment
  # @param role_id [String, nil] the role whose alignment re-opens; nil =
  #   the role the cycle assesses the person at
  # @raise [RuntimeError] if not in a cycle, wrong cycle, alignment not
  #   started against the role, or not completed
  def reopen_alignment(cycle_id, reopened_by_id:, role_id: nil)
    ensure_in_cycle!(cycle_id)
    role_id ||= @home_role_id
    alignment = @alignments[role_id]
    raise "Alignment has not been started for this cycle" unless alignment
    raise "Alignment is not completed for this cycle" unless alignment[:completed]

    apply(PersonDevelopment::Events::AlignmentReopened.new(data: {
      cycle_id: cycle_id,
      reopened_by_id: reopened_by_id,
      role_id: role_id
    }))
  end

  # ── Evidence ──
  #
  # Evidence is qualitative context anchored to one or more
  # (capability_stable_id, level_ordinal) coordinates — the same coordinate
  # as the behavioural expectation it's evidence for. A single piece of
  # evidence can demonstrate several capability × level expectations, so it
  # carries a SET of links. It does not feed scoring (see ADR-10 /
  # scoring-model.md) and does not freeze during alignment: add link /
  # remove link / withdraw remain available regardless of cycle status. The
  # aggregate must be assigned to a framework, but does not need to be in a
  # cycle.

  # Records a new piece of evidence. With a (capability, level) it is
  # PLACED: the item carries that first link, plus any additional links
  # applied atomically. Without one it is UNPLACED: feedback volunteered by
  # someone who knows what happened but not which expectation it speaks to,
  # recorded with no links and placed later through add_evidence_link by
  # anyone EvidencePolicy#add_link? admits.
  #
  # @param evidence_id [String] caller-supplied UUID v7 (caller owns idempotency)
  # @param capability_stable_id [String, nil] stable UUID of the capability
  #   (first link); nil with level_ordinal nil records the item unplaced
  # @param level_ordinal [Integer, nil] the level being evidenced (first link)
  # @param source [String] "self" | "manager" | "peer"
  # @param evidence_type [String] one of EVIDENCE_TYPES
  # @param content [String] the body of the evidence (required)
  # @param author_id [String] UUID of the Person recording the evidence
  # @param feedback_direction [String] immutable provider-to-recipient
  #   relationship at recording time
  # @param cycle_id [String, nil] cycle the evidence was provided for;
  #   defaults to the aggregate's current cycle
  # @param custom_type_label [String, nil] free text, only when evidence_type == "other"
  # @param title [String, nil] optional one-line summary
  # @param external_reference [Hash, nil] { system:, url:, external_id:, metadata: }
  # @param valence [String, nil] the origin link's valence — one of
  #   EVIDENCE_VALENCES. Required with a cell: every NEW link carries the
  #   linker's judgment (historical links stay nil forever; that's write-time
  #   law, not a data invariant). Must be nil for an unplaced item — there is
  #   no link for it to describe.
  # @param additional_links [Array<Hash>] extra links, each
  #   { capability_stable_id:, level_ordinal:, valence: }, applied as
  #   EvidenceLinkAdded in the same aggregate transaction. Duplicates (of
  #   the first link or each other) are rejected.
  # @param request_id [String, nil] the evidence request this item answers,
  #   when it is recorded as a response — carried on the event so a reader
  #   of EvidenceRecorded knows without waiting for the request's own event
  # @param recorded_at [Time, String, nil] when the feedback was given, for an
  #   item that arrives after the fact (an import); the event's own time otherwise
  # @raise [CommandError] if not assigned, evidence_id already exists, or args are invalid
  def record_evidence(evidence_id, source:, evidence_type:, content:, author_id:,
                      capability_stable_id: nil, level_ordinal: nil, valence: nil,
                      feedback_direction: default_feedback_direction(source),
                      custom_type_label: nil, title: nil,
                      external_reference: nil, additional_links: [], cycle_id: @current_cycle_id,
                      request_id: nil, recorded_at: nil)
    ensure_assigned!
    raise CommandError, "Evidence ID already exists" if @evidence.key?(evidence_id)
    raise CommandError, "Invalid evidence source: #{source}" unless EVIDENCE_SOURCES.include?(source)
    raise CommandError, "Evidence about yourself must be self evidence" if author_id == @person_id && source != "self"
    unless EVIDENCE_DIRECTIONS_BY_SOURCE.fetch(source).include?(feedback_direction)
      raise CommandError, "Invalid feedback direction: #{feedback_direction}"
    end
    raise CommandError, "Invalid evidence type: #{evidence_type}" unless EVIDENCE_TYPES.include?(evidence_type)
    ensure_evidence_origin!(capability_stable_id, level_ordinal, valence, additional_links)
    raise CommandError, "Custom type label required when evidence_type is 'other'" if
      evidence_type == "other" && custom_type_label.to_s.strip.empty?
    raise CommandError, "Custom type label only allowed when evidence_type is 'other'" if
      evidence_type != "other" && !custom_type_label.nil? && !custom_type_label.to_s.strip.empty?
    raise CommandError, "Evidence content cannot be blank" if content.to_s.strip.empty?

    data = {
      evidence_id: evidence_id,
      capability_stable_id: capability_stable_id,
      level_ordinal: level_ordinal,
      source: source,
      evidence_type: evidence_type,
      custom_type_label: custom_type_label,
      title: title,
      content: content,
      external_reference: external_reference,
      author_id: author_id,
      feedback_direction: feedback_direction,
      valence: valence,
      cycle_id: cycle_id,
      request_id: request_id
    }
    data[:recorded_at] = recorded_at_iso8601(recorded_at) if recorded_at
    apply(PersonDevelopment::Events::EvidenceRecorded.new(data: data))

    Array(additional_links).each do |link|
      add_evidence_link(evidence_id,
        capability_stable_id: link[:capability_stable_id],
        level_ordinal: link[:level_ordinal],
        linked_by_id: author_id,
        valence: link[:valence])
    end
  end

  # Links an existing evidence item to an additional (capability, level)
  # coordinate. The item then surfaces in that cell too.
  #
  # @param evidence_id [String] UUID of the evidence to link
  # @param capability_stable_id [String] target capability
  # @param level_ordinal [Integer] target level
  # @param linked_by_id [String] UUID of the Person adding the link
  # @param valence [String] the linker's judgment — one of
  #   EVIDENCE_VALENCES. Required on every new link.
  # @param rationale [String, nil] optional explanation of the link
  # @param via_suggestion_id [String, nil] the placement suggestion the
  #   linker accepted, when the link came from one
  # @raise [CommandError] if not assigned, evidence not found, withdrawn,
  #   already linked to that coordinate, or the valence is invalid
  def add_evidence_link(evidence_id, capability_stable_id:, level_ordinal:, linked_by_id:, valence:, rationale: nil,
                        via_suggestion_id: nil)
    ensure_assigned!
    state = @evidence[evidence_id]
    raise CommandError, "No evidence with id #{evidence_id}" unless state
    raise CommandError, "Cannot link withdrawn evidence" if state[:status] == "withdrawn"
    raise CommandError, "Invalid evidence valence: #{valence}" unless EVIDENCE_VALENCES.include?(valence)
    if state[:links].include?([ capability_stable_id, level_ordinal ])
      raise CommandError, "Evidence is already linked to that coordinate"
    end

    apply(PersonDevelopment::Events::EvidenceLinkAdded.new(data: {
      evidence_id: evidence_id,
      capability_stable_id: capability_stable_id,
      level_ordinal: level_ordinal,
      linked_by_id: linked_by_id,
      valence: valence,
      rationale: rationale
    }.merge(suggestion_attribution(via_suggestion_id))))
  end

  # Removes one of an evidence item's (capability, level) links. The item
  # stops appearing in that cell but keeps its other links.
  #
  # A PLACED evidence item must always retain at least one link —
  # removing the last link is rejected (withdraw the item instead). This
  # is a domain invariant; the UI also prevents the action. An unplaced
  # item has no link to remove, so the rule never meets it; its first
  # add_evidence_link places it and the rule applies from then on.
  #
  # @param evidence_id [String] UUID of the evidence to unlink
  # @param capability_stable_id [String] the link's capability
  # @param level_ordinal [Integer] the link's level
  # @param removed_by_id [String] UUID of the Person removing the link
  # @param reason [String, nil] optional explanation
  # @raise [CommandError] if not assigned, evidence not found, withdrawn,
  #   not linked to that coordinate, or it is the last remaining link
  def remove_evidence_link(evidence_id, capability_stable_id:, level_ordinal:, removed_by_id:, reason: nil)
    ensure_assigned!
    state = @evidence[evidence_id]
    raise CommandError, "No evidence with id #{evidence_id}" unless state
    raise CommandError, "Cannot unlink withdrawn evidence" if state[:status] == "withdrawn"
    unless state[:links].include?([ capability_stable_id, level_ordinal ])
      raise CommandError, "Evidence is not linked to that coordinate"
    end
    if state[:links].size <= 1
      raise CommandError, "Cannot remove the only link; withdraw the evidence instead"
    end

    apply(PersonDevelopment::Events::EvidenceLinkRemoved.new(data: {
      evidence_id: evidence_id,
      capability_stable_id: capability_stable_id,
      level_ordinal: level_ordinal,
      removed_by_id: removed_by_id,
      reason: reason
    }))
  end

  # Reclassifies an evidence link's valence — including classifying a
  # pre-valence (nil) link for the first time. Reclassification is an
  # explicit affordance, never a save-blocking gate: existing links pass
  # through content edits untouched unless the editor changes them.
  #
  # A no-op (no event) when the link already carries the requested
  # valence, so a full-state modal resubmit is safe.
  #
  # @param evidence_id [String] UUID of the evidence
  # @param capability_stable_id [String] the link's capability
  # @param level_ordinal [Integer] the link's level
  # @param valence [String] one of EVIDENCE_VALENCES
  # @param changed_by_id [String] UUID of the Person reclassifying
  # @param via_suggestion_id [String, nil] the placement suggestion the
  #   reclassifier accepted, when the new valence came from one
  # @raise [CommandError] if not assigned, evidence not found, withdrawn,
  #   not linked to that coordinate, or the valence is invalid
  def set_evidence_link_valence(evidence_id, capability_stable_id:, level_ordinal:, valence:, changed_by_id:,
                                via_suggestion_id: nil)
    ensure_assigned!
    state = @evidence[evidence_id]
    raise CommandError, "No evidence with id #{evidence_id}" unless state
    raise CommandError, "Cannot reclassify withdrawn evidence" if state[:status] == "withdrawn"
    raise CommandError, "Invalid evidence valence: #{valence}" unless EVIDENCE_VALENCES.include?(valence)
    unless state[:links].include?([ capability_stable_id, level_ordinal ])
      raise CommandError, "Evidence is not linked to that coordinate"
    end

    previous = state[:links][[ capability_stable_id, level_ordinal ]]
    return if previous == valence

    apply(PersonDevelopment::Events::EvidenceLinkRevalenced.new(data: {
      evidence_id: evidence_id,
      capability_stable_id: capability_stable_id,
      level_ordinal: level_ordinal,
      previous_valence: previous,
      valence: valence,
      changed_by_id: changed_by_id
    }.merge(suggestion_attribution(via_suggestion_id))))
  end

  # Edits the user-correctable fields of an existing evidence item.
  #
  # Mutable: `title`, `content`, `evidence_type` (+ `custom_type_label`),
  # `external_reference`. The capability/level links are owned by
  # {#add_evidence_link} / {#remove_evidence_link};
  # `source`/`author_id`/`recorded_at` are identity invariants and never
  # change. The full post-edit value of every mutable field is recorded
  # on the event (snapshot, not a delta).
  #
  # @param evidence_id [String] UUID of the evidence being edited
  # @param title [String, nil] post-edit title
  # @param content [String] post-edit content (required, non-blank)
  # @param evidence_type [String] one of EVIDENCE_TYPES
  # @param custom_type_label [String, nil] required iff evidence_type == "other"
  # @param external_reference [Hash, nil] { system:, url:, external_id:, metadata: }
  # @param edited_by_id [String] UUID of the Person performing the edit
  # @raise [CommandError] if not assigned, evidence not found, withdrawn,
  #   or the new values are invalid
  def update_evidence(evidence_id, title:, content:, evidence_type:,
                      custom_type_label:, external_reference:, edited_by_id:)
    ensure_assigned!
    state = @evidence[evidence_id]
    raise CommandError, "No evidence with id #{evidence_id}" unless state
    raise CommandError, "Cannot update withdrawn evidence" if state[:status] == "withdrawn"
    raise CommandError, "Invalid evidence type: #{evidence_type}" unless EVIDENCE_TYPES.include?(evidence_type)
    raise CommandError, "Custom type label required when evidence_type is 'other'" if
      evidence_type == "other" && custom_type_label.to_s.strip.empty?
    raise CommandError, "Custom type label only allowed when evidence_type is 'other'" if
      evidence_type != "other" && !custom_type_label.nil? && !custom_type_label.to_s.strip.empty?
    raise CommandError, "Evidence content cannot be blank" if content.to_s.strip.empty?

    apply(PersonDevelopment::Events::EvidenceUpdated.new(data: {
      evidence_id: evidence_id,
      title: title,
      content: content,
      evidence_type: evidence_type,
      custom_type_label: custom_type_label,
      external_reference: external_reference,
      edited_by_id: edited_by_id
    }))
  end

  # Soft-deletes an evidence item. Original record stays in history;
  # the read model flips `link_status` to "withdrawn".
  #
  # @param evidence_id [String] UUID of the evidence
  # @param withdrawn_by_id [String] UUID of the Person withdrawing
  # @param reason [String, nil] optional explanation
  # @raise [CommandError] if not assigned, evidence not found, or already withdrawn
  def withdraw_evidence(evidence_id, withdrawn_by_id:, reason: nil)
    ensure_assigned!
    state = @evidence[evidence_id]
    raise CommandError, "No evidence with id #{evidence_id}" unless state
    raise CommandError, "Evidence already withdrawn" if state[:status] == "withdrawn"

    apply(PersonDevelopment::Events::EvidenceWithdrawn.new(data: {
      evidence_id: evidence_id,
      withdrawn_by_id: withdrawn_by_id,
      reason: reason
    }))
  end

  # ── Evidence requests ──
  #
  # A cell-scoped ask for peer evidence. The requester is the assessee or
  # someone in their manager chain (enforced by policy); the requestee is any
  # other person. Lifecycle: pending → responded | declined | cancelled.

  # Ask a colleague for evidence about a specific (capability, level) cell.
  #
  # @param request_id [String] UUID v7 minted at command time
  # @param requested_by_id [String] Person making the request
  # @param requestee_person_id [String] Person being asked
  # @param capability_stable_id [String] stable UUID of the capability
  # @param level_ordinal [Integer] the level the evidence is about
  # @param message [String, nil] optional note to the requestee
  # @param due_at [String, nil] optional ISO8601 due date
  # @raise [CommandError] if not assigned, id exists, or requestee is the assessee
  def request_evidence(request_id, requested_by_id:, requestee_person_id:, capability_stable_id:,
                       level_ordinal:, message: nil, due_at: nil)
    ensure_assigned!
    raise CommandError, "Evidence request ID already exists" if @evidence_requests.key?(request_id)
    # The assessee is a valid requestee (a manager can ask them for more
    # evidence) — only asking yourself is meaningless.
    raise CommandError, "Cannot request evidence from yourself" if requestee_person_id == requested_by_id

    apply(PersonDevelopment::Events::EvidenceRequested.new(data: {
      request_id: request_id,
      requested_by_id: requested_by_id,
      requestee_person_id: requestee_person_id,
      capability_stable_id: capability_stable_id,
      level_ordinal: level_ordinal,
      message: message,
      due_at: due_at,
      cycle_id: @current_cycle_id
    }))
  end

  # Fulfil a pending request by linking the evidence the requestee provided.
  #
  # @param request_id [String]
  # @param evidence_id [String] the EvidenceRecorded item provided in response
  # @param responded_by_id [String] the requestee
  # @raise [CommandError] if not assigned, request unknown, or not pending
  def respond_to_evidence_request(request_id, evidence_id:, responded_by_id:)
    state = pending_request!(request_id)
    raise CommandError, "Unknown evidence ID" unless @evidence.key?(evidence_id)

    apply(PersonDevelopment::Events::EvidenceRequestResponded.new(data: {
      request_id: request_id,
      evidence_id: evidence_id,
      responded_by_id: responded_by_id
    }))
    state
  end

  # Decline a pending request, optionally with a reason.
  #
  # @raise [CommandError] if not assigned, request unknown, or not pending
  def decline_evidence_request(request_id, declined_by_id:, reason: nil)
    pending_request!(request_id)

    apply(PersonDevelopment::Events::EvidenceRequestDeclined.new(data: {
      request_id: request_id,
      declined_by_id: declined_by_id,
      reason: reason
    }))
  end

  # Record that the requestee was nudged about a still-pending request.
  #
  # Automatic kinds ("no_response" / "due_soon", from the reminder sweep)
  # fire at most once per request, so a sweep that races a response — or
  # re-runs — is rejected here rather than double-pinging the requestee.
  # "manual" (a requester-initiated nudge, carrying `nudged_by_id`) may
  # repeat, but never within EVIDENCE_REQUEST_NUDGE_GAP of the last reminder
  # of any kind — enforced here as well as at the operation layer, so two
  # near-simultaneous nudges can't both land.
  #
  # @param kind [String] "no_response" | "due_soon" | "manual"
  # @param nudged_by_id [String, nil] the Person nudging (manual kind only)
  # @raise [CommandError] if not assigned, request unknown, not pending,
  #   kind unknown, an automatic kind was already sent, or a manual nudge
  #   lands within the gap
  def remind_evidence_request(request_id, kind:, nudged_by_id: nil)
    state = pending_request!(request_id)
    raise CommandError, "Unknown reminder kind #{kind}" unless EVIDENCE_REQUEST_REMINDER_KINDS.include?(kind.to_s)
    if kind.to_s != "manual" && state[:reminder_kinds]&.include?(kind.to_s)
      raise CommandError, "#{kind} reminder already sent"
    end
    if kind.to_s == "manual" && state[:last_reminded_at] &&
       Time.current < state[:last_reminded_at] + EVIDENCE_REQUEST_NUDGE_GAP
      raise CommandError, "A reminder was sent within the last 2 days"
    end

    apply(PersonDevelopment::Events::EvidenceRequestReminderSent.new(data: {
      request_id: request_id,
      kind: kind.to_s,
      nudged_by_id: nudged_by_id
    }))
  end

  # Cancel a still-pending request (requester or admin).
  #
  # @raise [CommandError] if not assigned, request unknown, or not pending
  def cancel_evidence_request(request_id, cancelled_by_id:)
    pending_request!(request_id)

    apply(PersonDevelopment::Events::EvidenceRequestCancelled.new(data: {
      request_id: request_id,
      cancelled_by_id: cancelled_by_id
    }))
  end

  # ── Comments ──
  #
  # Comments are informal-conversation context. They do not feed scoring
  # and do not freeze during alignment — posting / editing / deleting
  # remain available regardless of cycle status. Both current commentable
  # types anchor to (capability_stable_id, level_ordinal) cells:
  # "assessment_cell" (discussion about the behaviour at the cell) and
  # "evidence_link" (discussion about one evidence item's bearing on the
  # cell — additionally anchored by evidence_id). Future commentable types
  # (growth_plan, focus_area, check_in) will set their own identifier shape.

  COMMENT_COMMENTABLE_TYPES = [
    PersonDevelopmentComment::ASSESSMENT_CELL,
    PersonDevelopmentComment::EVIDENCE_LINK
  ].freeze

  # Posts a new comment.
  #
  # @param comment_id [String] caller-supplied UUID v7 (caller owns idempotency)
  # @param commentable_type [String] currently only "assessment_cell"
  # @param body [String] comment body (required, non-blank)
  # @param author_id [String] UUID of the Person posting the comment
  # @param capability_stable_id [String, nil] required for both current
  #   commentable types
  # @param level_ordinal [Integer, nil] required for both current
  #   commentable types
  # @param evidence_id [String, nil] required when commentable_type is
  #   "evidence_link" — the {EvidenceItem} whose linkage is under discussion
  # @param parent_id [String, nil] UUID of the comment being replied to;
  #   nil for a top-level comment
  # @raise [CommandError] if not assigned, comment_id already exists, or
  #   args are invalid
  def post_comment(comment_id, commentable_type:, body:, author_id:,
                   capability_stable_id: nil, level_ordinal: nil,
                   evidence_id: nil, parent_id: nil)
    ensure_assigned!
    raise CommandError, "Comment ID already exists" if @comments.key?(comment_id)
    raise CommandError, "Invalid commentable type: #{commentable_type}" unless
      COMMENT_COMMENTABLE_TYPES.include?(commentable_type)
    raise CommandError, "Comment body cannot be blank" if body.to_s.strip.empty?

    raise CommandError, "capability_stable_id required for #{commentable_type} comments" if
      capability_stable_id.to_s.strip.empty?
    raise CommandError, "level_ordinal required for #{commentable_type} comments" if
      level_ordinal.to_s.strip.empty?

    if commentable_type == PersonDevelopmentComment::EVIDENCE_LINK
      raise CommandError, "evidence_id required for evidence_link comments" if
        evidence_id.to_s.strip.empty?
      evidence = @evidence[evidence_id]
      raise CommandError, "Unknown evidence ID" unless evidence
      # Withdrawal retracts the artifact itself — its threads go read-only.
      raise CommandError, "Cannot comment on withdrawn evidence" if
        evidence[:status] == "withdrawn"
      # The thread anchors to the linkage's natural key, and deliberately
      # accepts a linkage that EVER existed (not just active ones): the
      # discussion often motivates the removal, and the thread staying
      # open afterwards — "removed per the above" — is a design decision.
      raise CommandError, "Evidence was never linked to that capability × level" unless
        evidence[:ever_linked].include?([ capability_stable_id, level_ordinal ])
    end

    if parent_id
      parent = @comments[parent_id]
      raise CommandError, "No parent comment with id #{parent_id}" unless parent
      raise CommandError, "Cannot reply to a deleted comment" if parent[:status] == "deleted"
      # A reply may target ANY non-deleted comment on the cell, including
      # another reply. Display is flat (see Comments::Thread) — depth is
      # unbounded in the data and a reply simply records which comment it
      # answered via parent_id. No cycle risk: the parent must already
      # exist in @comments before its child is posted, so links only ever
      # point backwards in time.
      # Replies must share their parent's anchor. Without this, a reply
      # could be posted on a different (capability, level) cell than its
      # parent, and the projection's group-by-parent thread tree would
      # show the reply orphaned from its parent's cell.
      raise CommandError, "Reply must share parent's commentable type" unless
        parent[:commentable_type] == commentable_type
      raise CommandError, "Reply must stay on the parent's cell" unless
        parent[:capability_stable_id] == capability_stable_id &&
        parent[:level_ordinal] == level_ordinal
      if commentable_type == PersonDevelopmentComment::EVIDENCE_LINK
        raise CommandError, "Reply must stay on the parent's evidence linkage" unless
          parent[:evidence_id] == evidence_id
      end
    end

    apply(PersonDevelopment::Events::CommentPosted.new(data: {
      comment_id: comment_id,
      parent_id: parent_id,
      commentable_type: commentable_type,
      capability_stable_id: capability_stable_id,
      level_ordinal: level_ordinal,
      evidence_id: evidence_id,
      body: body,
      author_id: author_id
    }))
  end

  # Edits the body of an existing comment.
  #
  # @param comment_id [String] UUID of the comment
  # @param body [String] post-edit body (required, non-blank)
  # @param edited_by_id [String] UUID of the Person editing (must equal the author)
  # @raise [CommandError] if not assigned, comment not found, deleted, or body blank
  def edit_comment(comment_id, body:, edited_by_id:)
    ensure_assigned!
    state = @comments[comment_id]
    raise CommandError, "No comment with id #{comment_id}" unless state
    raise CommandError, "Cannot edit a deleted comment" if state[:status] == "deleted"
    ensure_comment_thread_mutable!(state)
    raise CommandError, "Comment body cannot be blank" if body.to_s.strip.empty?
    raise CommandError, "Only the author can edit a comment" unless state[:author_id] == edited_by_id

    apply(PersonDevelopment::Events::CommentEdited.new(data: {
      comment_id: comment_id,
      body: body,
      edited_by_id: edited_by_id
    }))
  end

  # Soft-deletes a comment.
  #
  # @param comment_id [String] UUID of the comment
  # @param deleted_by_id [String] UUID of the Person deleting
  # @param reason [String, nil] optional explanation
  # @raise [CommandError] if not assigned, comment not found, or already deleted
  def delete_comment(comment_id, deleted_by_id:, reason: nil)
    ensure_assigned!
    state = @comments[comment_id]
    raise CommandError, "No comment with id #{comment_id}" unless state
    raise CommandError, "Comment already deleted" if state[:status] == "deleted"
    ensure_comment_thread_mutable!(state)

    apply(PersonDevelopment::Events::CommentDeleted.new(data: {
      comment_id: comment_id,
      deleted_by_id: deleted_by_id,
      reason: reason
    }))
  end

  private

  def recorded_at_iso8601(value)
    time = value.is_a?(String) ? Time.iso8601(value) : value
    time.utc.iso8601(6)
  rescue ArgumentError
    raise CommandError, "Invalid recorded_at: #{value}"
  end

  # Present only when a link decision came from a placement suggestion, so
  # every event published without one keeps its exact historical shape.
  def suggestion_attribution(via_suggestion_id)
    via_suggestion_id.present? ? { via_suggestion_id: via_suggestion_id } : {}
  end

  # Direct aggregate callers cannot inspect the org chart. The command handler
  # supplies the exact value; this source-based default keeps lower-level
  # domain calls classified for self, manager, and lateral feedback.
  # A cell is both halves or neither. With a cell the valence is the first
  # link's and is required; without one there is no link for a valence or
  # for additional links to follow.
  def ensure_evidence_origin!(capability_stable_id, level_ordinal, valence, additional_links)
    if capability_stable_id.nil? && level_ordinal.nil?
      raise CommandError, "Valence needs a capability and level to describe" unless valence.nil?
      raise CommandError, "Additional links need a first link to follow" if Array(additional_links).any?
      return
    end
    if capability_stable_id.nil? || level_ordinal.nil?
      raise CommandError, "Placing evidence needs both a capability and a level"
    end
    raise CommandError, "Invalid evidence valence: #{valence}" unless EVIDENCE_VALENCES.include?(valence)
  end

  def default_feedback_direction(source)
    {
      "self" => "self",
      "manager" => "manager_to_report",
      "peer" => "peer_to_peer"
    }[source]
  end

  # A person who moves into the role and level they were exploring has
  # arrived: the exploration closes as `moved`, attributed to whoever made
  # the move (nil for an HRIS sync). Left open, it would name the record
  # itself, where the lens banner — and so the Stop — never renders.
  def close_explorations_moved_into(changed_by)
    @explorations.each do |exploration_id, state|
      next unless state[:open] && state[:target_role_id] == @role_id && state[:target_level_id] == @level_id

      apply(PersonDevelopment::Events::ExplorationClosed.new(data: {
        exploration_id: exploration_id, closed_by_id: changed_by, outcome: "moved", note: nil
      }))
    end
  end

  def ensure_assigned!
    raise "Person not yet assigned to a framework" unless @assigned
  end

  # Shared state reset for the two cycle-exit events — one place to extend
  # when cycle-exit clearing grows, so leave and conclude can't diverge.
  def reset_cycle_exit_state
    @current_cycle_id = nil
    @alignments = {}
  end

  # Withdrawal retracts the evidence artifact itself, so its linkage
  # threads are read-only in full: no new posts (checked in
  # post_comment) AND no edits or deletes of what was already said.
  # Cell comments (no evidence_id) are never affected.
  def ensure_comment_thread_mutable!(comment_state)
    evidence_id = comment_state[:evidence_id]
    return unless evidence_id

    evidence = @evidence[evidence_id]
    raise CommandError, "Cannot modify comments on withdrawn evidence" if
      evidence && evidence[:status] == "withdrawn"
  end

  # Fetch an evidence request that must exist and still be pending.
  #
  # @return [Hash] the request's in-memory state
  # @raise [CommandError]
  def pending_request!(request_id)
    ensure_assigned!
    state = @evidence_requests[request_id]
    raise CommandError, "No evidence request with id #{request_id}" unless state
    raise CommandError, "Evidence request is not pending" unless state[:status] == "pending"

    state
  end

  def ensure_in_cycle!(expected_cycle_id)
    ensure_assigned!
    raise "Not currently in an assessment cycle" if @current_cycle_id.nil?
    raise "Cycle ID does not match current cycle" unless @current_cycle_id == expected_cycle_id
  end

  # A self or manager rating is frozen once any alignment started this cycle
  # reads its cell (ADR-22) — the union, so a shared cell can't be rated
  # under one role while another role's conversation is about it.
  def ensure_individual_ratings_unfrozen!(capability_stable_id, level_ordinal)
    key = [ capability_stable_id, level_ordinal ]
    raise "Self and manager ratings are frozen during alignment" if
      @alignments.each_value.any? { |alignment| covers?(alignment, key) }
  end

  # An agreed value can be recorded or cleared while an alignment reading
  # the cell is in progress — and never over one a completed alignment
  # already agreed, which is that conversation's record.
  def ensure_alignable!(key, role_id: nil)
    raise "Alignment has not been started for this cycle" if @alignments.empty?

    covering = @alignments.values.select { |alignment| covers?(alignment, key) }
    named = @alignments[role_id] if role_id
    covering << named if named && !named[:completed] && !covering.include?(named)
    raise "Alignment has not been started against a role that reads this cell" if covering.empty?

    completed, in_progress = covering.partition { |alignment| alignment[:completed] }
    raise "Alignment has been completed for this cycle" if in_progress.empty?
    raise "Alignment has been completed for this cycle" if completed.any? && @aligned_ratings.key?(key)
  end

  # @return [Boolean]
  def covers?(alignment, key)
    alignment[:cells] == :all || alignment[:cells].include?(key)
  end

  # @return [Boolean] the record's own alignment has been completed
  def home_alignment_completed?
    @alignments[@home_role_id]&.fetch(:completed) || false
  end

  # Domain invariant: a manager rating must be attributable to the recorded
  # reporting manager or an active delegate.
  #
  # Fail-open cases (defer to the controller-side Pundit check):
  # * non-"human" sources (seeded / system carry-forwards)
  # * no recorded manager yet (manual tenant / pre-backfill) — `@manager_id` nil
  #
  # Rollout is two-stage: Stage 1 (current) logs divergence; Stage 2 will raise
  # {CommandError}. See docs/guidelines/event-sourcing.md and the feature plan.
  # Expiry is honoured here (via {#delegate_active?}), so the guard and the
  # policy's `ManagerAssessmentDelegation.active` scope agree on lapsed grants.
  #
  # @param rated_by_id [String, nil]
  # @param source [String]
  def ensure_manager_authority!(rated_by_id, source)
    return unless source == "human"
    return if @manager_id.nil?
    return if rated_by_id == @manager_id
    return if delegate_active?(rated_by_id)

    Rails.logger.warn(
      "[manager-authority] PersonDev-#{@person_id}-#{@framework_id}: rated_by_id=#{rated_by_id.inspect} " \
      "is neither the recorded manager (#{@manager_id.inspect}) nor an active delegate " \
      "(#{@active_delegates.keys.inspect}). Allowed under Stage 1 soft guard."
    )
  end

  # Whether a manager rating attributed to `rated_by_id` is being recorded via an
  # active delegation rather than by the recorded reporting manager. Stamped on
  # the rating event so the activity feed badges it accurately at event time
  # (rather than reconstructing from current read-model state).
  #
  # @return [Boolean]
  def rated_via_delegation?(rated_by_id)
    rated_by_id.present? && rated_by_id != @manager_id && delegate_active?(rated_by_id)
  end

  # Whether the person currently holds a non-expired delegation. Wall-clock
  # comparison is safe here because the guard runs at command time, not replay.
  #
  # @return [Boolean]
  def delegate_active?(delegate_person_id)
    return false unless @active_delegates.key?(delegate_person_id)

    expires_at = @active_delegates[delegate_person_id]
    return true if expires_at.blank?

    parsed = expires_at.is_a?(Time) || expires_at.is_a?(ActiveSupport::TimeWithZone) ? expires_at : Time.zone.parse(expires_at.to_s)
    parsed.nil? || parsed > Time.current
  rescue ArgumentError
    true # unparseable expiry → treat as open-ended rather than locking out
  end

  # ── Event handlers ──

  on PersonDevelopment::Events::ReportingManagerRecorded do |event|
    @manager_id = event.data[:manager_id]
  end

  on PersonDevelopment::Events::ManagerRatingDelegated do |event|
    @active_delegates[event.data[:delegate_person_id]] = event.data[:expires_at]
  end

  on PersonDevelopment::Events::RatingRevisitRequested do |_event|
    # No aggregate state: resolution is rating-change-based, computed at
    # read time — see #request_rating_revisit.
  end

  on PersonDevelopment::Events::ManagerRatingDelegationRevoked do |event|
    @active_delegates.delete(event.data[:delegate_person_id])
  end

  on PersonDevelopment::Events::ExplorationStarted do |event|
    @explorations[event.data[:exploration_id]] = {
      target_role_id: event.data[:target_role_id], target_level_id: event.data[:target_level_id], open: true
    }
  end

  on PersonDevelopment::Events::ExplorationClosed do |event|
    state = @explorations[event.data[:exploration_id]]
    state[:open] = false if state
  end

  on PersonDevelopment::Events::PersonAssignedToFramework do |event|
    @person_id = event.data[:person_id]
    @framework_id = event.data[:framework_id]
    @role_id = event.data[:role_id]
    @level_id = event.data[:level_id]
    @assigned = true
  end

  on PersonDevelopment::Events::PersonRoleChanged do |event|
    @role_id = event.data[:new_role_id]
    @level_id = event.data[:new_level_id]
  end

  on PersonDevelopment::Events::PersonLevelChanged do |event|
    @level_id = event.data[:new_level_id]
  end

  on PersonDevelopment::Events::PersonUnassignedFromFramework do |_event|
    @role_id = nil
    @level_id = nil
    @assigned = false
  end

  on PersonDevelopment::Events::FrameworkVersionMigrated do |event|
    @last_migrated_to_version = event.data[:new_version]
    # The current cycle is now assessed against the migrated-to version.
    @assessed_framework_version = event.data[:new_version]

    # Follow the same/evolved mappings for the anchors the comment
    # commands validate against — mirroring how the CommentThread
    # projection re-keys the read model. Without this, a post or reply on
    # an evidence-link thread whose capability was evolved would arrive
    # with the survivor stable_id and fail the ever-linked / parent-cell
    # checks against the pre-migration id still held here.
    event.data[:mappings].each do |mapping|
      next unless %w[same evolved].include?(mapping[:mapping_type])
      next if mapping[:to_stable_id].nil?

      from = mapping[:from_stable_id]
      to = mapping[:to_stable_id]

      @comments.each_value do |comment|
        comment[:capability_stable_id] = to if comment[:capability_stable_id] == from
      end
      @evidence.each_value do |evidence|
        # Active links too — remove/revalence/duplicate checks must
        # accept the survivor id the re-keyed read model now presents.
        evidence[:links] = evidence[:links].to_h { |(cap, ordinal), valence|
          [ [ cap == from ? to : cap, ordinal ], valence ]
        }
        evidence[:ever_linked] = evidence[:ever_linked].map { |cap, ordinal|
          [ cap == from ? to : cap, ordinal ]
        }.to_set
      end
      # A role's frozen cells follow the survivor too, or a mid-alignment
      # publish would thaw the evolved capability's cells.
      @alignments.each_value do |alignment|
        next if alignment[:cells] == :all

        alignment[:cells] = alignment[:cells].to_set { |cap, ordinal| [ cap == from ? to : cap, ordinal ] }
      end
    end
  end

  on PersonDevelopment::Events::JoinedAssessmentCycle do |event|
    @current_cycle_id = event.data[:cycle_id]
    @assessed_framework_version = event.data[:framework_version]
    @home_role_id = @role_id
    @alignments = {}
    @self_ratings = {}
    @manager_ratings = {}
    @self_rating_sources = {}
    @manager_rating_sources = {}
    @aligned_ratings = {}
  end

  on PersonDevelopment::Events::LeftAssessmentCycle do |_event|
    reset_cycle_exit_state
  end

  on PersonDevelopment::Events::AssessmentCycleConcluded do |_event|
    reset_cycle_exit_state
  end

  # A historical start carries neither a role nor cells: it is the home
  # role's and it froze the whole assessment, so replaying it must too —
  # otherwise every open cycle that started alignment before per-role
  # alignment would silently thaw on its next load.
  on PersonDevelopment::Events::AlignmentStarted do |event|
    cell_keys = event.data[:cell_keys]
    @alignments[event.data[:role_id] || @home_role_id] = {
      completed: false,
      cells: cell_keys ? cell_keys.to_set { |stable_id, ordinal| [ stable_id, ordinal ] } : :all
    }
  end

  on PersonDevelopment::Events::FullAlignmentCompleted do |event|
    alignment = @alignments[event.data[:role_id] || @home_role_id]
    alignment[:completed] = true if alignment
  end

  on PersonDevelopment::Events::AlignmentReopened do |event|
    # Back to the aligning phase — agreed values (@aligned_ratings) are
    # deliberately left intact so the manager resumes where they left off.
    alignment = @alignments[event.data[:role_id] || @home_role_id]
    alignment[:completed] = false if alignment
  end

  on PersonDevelopment::Events::RatingSeedSkipped do |_event|
    # Audit-only — no aggregate state to mutate.
  end

  on PersonDevelopment::Events::SelfRated do |event|
    key = [ event.data[:capability_stable_id], event.data[:level_ordinal] ]
    @self_ratings[key] = event.data[:frequency]
    @self_rating_sources[key] = event.data[:source]
  end

  on PersonDevelopment::Events::SelfRatingRevised do |event|
    key = [ event.data[:capability_stable_id], event.data[:level_ordinal] ]
    @self_ratings[key] = event.data[:frequency]
    @self_rating_sources[key] = "human"
  end

  on PersonDevelopment::Events::SelfRatingCleared do |event|
    key = [ event.data[:capability_stable_id], event.data[:level_ordinal] ]
    @self_ratings.delete(key)
    @self_rating_sources.delete(key)
  end

  on PersonDevelopment::Events::ManagerRated do |event|
    key = [ event.data[:capability_stable_id], event.data[:level_ordinal] ]
    @manager_ratings[key] = event.data[:frequency]
    @manager_rating_sources[key] = event.data[:source]
  end

  on PersonDevelopment::Events::ManagerRatingRevised do |event|
    key = [ event.data[:capability_stable_id], event.data[:level_ordinal] ]
    @manager_ratings[key] = event.data[:frequency]
    @manager_rating_sources[key] = "human"
  end

  on PersonDevelopment::Events::ManagerRatingCleared do |event|
    key = [ event.data[:capability_stable_id], event.data[:level_ordinal] ]
    @manager_ratings.delete(key)
    @manager_rating_sources.delete(key)
  end

  on PersonDevelopment::Events::AssessmentAligned do |event|
    key = [ event.data[:capability_stable_id], event.data[:level_ordinal] ]
    @aligned_ratings[key] = event.data[:aligned_frequency]
    # An agreement made against a role counts the cell as that role's —
    # absent on every event before per-role alignment.
    alignment = @alignments[event.data[:role_id]] if event.data[:role_id]
    alignment[:cells] << key if alignment && alignment[:cells] != :all
  end

  on PersonDevelopment::Events::AlignmentCleared do |event|
    @aligned_ratings.delete([ event.data[:capability_stable_id], event.data[:level_ordinal] ])
  end

  # `links` maps [capability_stable_id, level_ordinal] => valence. Valence
  # is nil for links from events published before valence existed —
  # `event.data[:valence]` on those simply returns nil (Lesson 15: keys
  # here must match what the commands above publish).
  on PersonDevelopment::Events::EvidenceRecorded do |event|
    # An unplaced item (no capability on the event) starts with no links.
    origin = event.data[:capability_stable_id] && [ event.data[:capability_stable_id], event.data[:level_ordinal] ]
    @evidence[event.data[:evidence_id]] = {
      links: origin ? { origin => event.data[:valence] } : {},
      # Every cell this item was EVER linked to — removal doesn't erase
      # membership. Backs the evidence_link comment-thread anchor, which
      # stays valid after the link is removed (post_comment above).
      ever_linked: Set.new([ origin ].compact),
      status: "active"
    }
  end

  on PersonDevelopment::Events::EvidenceLinkAdded do |event|
    state = @evidence[event.data[:evidence_id]]
    next unless state

    key = [ event.data[:capability_stable_id], event.data[:level_ordinal] ]
    state[:links][key] = event.data[:valence]
    state[:ever_linked] << key
  end

  on PersonDevelopment::Events::EvidenceLinkRemoved do |event|
    state = @evidence[event.data[:evidence_id]]
    next unless state

    state[:links].delete([ event.data[:capability_stable_id], event.data[:level_ordinal] ])
  end

  on PersonDevelopment::Events::EvidenceLinkRevalenced do |event|
    state = @evidence[event.data[:evidence_id]]
    next unless state

    state[:links][[ event.data[:capability_stable_id], event.data[:level_ordinal] ]] = event.data[:valence]
  end

  # Historical event — no longer emitted (the user-facing "move" action was
  # dropped in favour of add-link + remove-link). Retained so replay of
  # streams that contain it reconstructs the link set correctly: a relink is
  # "remove the previous link, add the new one" (pre-valence, so nil).
  on PersonDevelopment::Events::EvidenceRelinked do |event|
    state = @evidence[event.data[:evidence_id]]
    next unless state

    state[:links].delete([ event.data[:previous_capability_stable_id], event.data[:previous_level_ordinal] ])
    new_key = [ event.data[:new_capability_stable_id], event.data[:new_level_ordinal] ]
    state[:links][new_key] = nil
    state[:ever_linked] << new_key
  end

  on PersonDevelopment::Events::EvidenceWithdrawn do |event|
    state = @evidence[event.data[:evidence_id]]
    next unless state

    state[:status] = "withdrawn"
  end

  # No-op for aggregate state: `update_evidence` only touches content
  # fields (title/content/type/external_reference) that the aggregate
  # does not track. Handler is declared so the event has a registered
  # applier on the aggregate.
  on PersonDevelopment::Events::EvidenceUpdated do |_event|
  end

  on PersonDevelopment::Events::EvidenceRequested do |event|
    @evidence_requests[event.data[:request_id]] = {
      status: "pending",
      requestee_person_id: event.data[:requestee_person_id],
      capability_stable_id: event.data[:capability_stable_id],
      level_ordinal: event.data[:level_ordinal],
      reminder_kinds: []
    }
  end

  on PersonDevelopment::Events::EvidenceRequestReminderSent do |event|
    state = @evidence_requests[event.data[:request_id]]
    if state
      (state[:reminder_kinds] ||= []) << event.data[:kind]
      # Loaded events carry the publish timestamp; a freshly-applied event
      # hasn't been stamped yet, so "now" is the accurate value.
      state[:last_reminded_at] = event.metadata[:timestamp] || Time.current
    end
  end

  on PersonDevelopment::Events::EvidenceRequestResponded do |event|
    state = @evidence_requests[event.data[:request_id]]
    state[:status] = "responded" if state
  end

  on PersonDevelopment::Events::EvidenceRequestDeclined do |event|
    state = @evidence_requests[event.data[:request_id]]
    state[:status] = "declined" if state
  end

  on PersonDevelopment::Events::EvidenceRequestCancelled do |event|
    state = @evidence_requests[event.data[:request_id]]
    state[:status] = "cancelled" if state
  end

  on PersonDevelopment::Events::CommentPosted do |event|
    @comments[event.data[:comment_id]] = {
      commentable_type: event.data[:commentable_type],
      capability_stable_id: event.data[:capability_stable_id],
      level_ordinal: event.data[:level_ordinal],
      evidence_id: event.data[:evidence_id],
      parent_id: event.data[:parent_id],
      author_id: event.data[:author_id],
      status: "active"
    }
  end

  # No body tracking on the aggregate — content lives in the projection.
  # Handler is declared so the event has a registered applier.
  on PersonDevelopment::Events::CommentEdited do |_event|
  end

  on PersonDevelopment::Events::CommentDeleted do |event|
    state = @comments[event.data[:comment_id]]
    next unless state

    state[:status] = "deleted"
  end
end
