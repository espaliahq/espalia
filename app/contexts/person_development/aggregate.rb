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
# cross-stream sync handler. `join_cycle` / `leave_cycle` are called ONLY by
# that sync handler in response to PersonEnrolled / PersonUnenrolled events —
# never by controllers.
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

  def initialize
    @person_id = nil
    @framework_id = nil
    @role_id = nil
    @level_id = nil
    @assigned = false
    @current_cycle_id = nil
    @alignment_started = false
    @alignment_completed = false
    @self_ratings = {}   # [stable_id, level_ordinal] => frequency
    @manager_ratings = {} # [stable_id, level_ordinal] => frequency
    @evidence = {}       # evidence_id => { capability_stable_id:, level_ordinal:, status: }
    @comments = {}       # comment_id => { commentable_type:, capability_stable_id:, level_ordinal:, parent_id:, author_id:, status: }
  end

  # ── Assignment ──

  # Assigns a person to a framework with a specific role and level.
  #
  # @param person_id [String] UUID of the person
  # @param framework_id [String] UUID of the framework
  # @param role_id [String] UUID of the assigned role
  # @param level_id [String] UUID of the assigned level
  # @raise [RuntimeError] if already assigned
  def assign_to_framework(person_id, framework_id, role_id, level_id)
    raise "Person already assigned to this framework" if @assigned

    apply(PersonDevelopment::Events::PersonAssignedToFramework.new(data: {
      person_id: person_id,
      framework_id: framework_id,
      role_id: role_id,
      level_id: level_id
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
  # @raise [RuntimeError] if not yet assigned, or if role is unchanged
  def change_role(new_role_id, new_level_id, reason: "hris_sync")
    ensure_assigned!
    raise "Role unchanged" if @role_id == new_role_id

    apply(PersonDevelopment::Events::PersonRoleChanged.new(data: {
      previous_role_id: @role_id,
      new_role_id: new_role_id,
      previous_level_id: @level_id,
      new_level_id: new_level_id,
      reason: reason
    }))
  end

  # Changes a person's level within the same role (promotion).
  #
  # @param new_level_id [String] UUID of the new level (must belong to current role)
  # @param reason [String] why the change occurred (e.g. "hris_sync", "manual")
  # @raise [RuntimeError] if not yet assigned, or if level is unchanged
  def change_level(new_level_id, reason: "hris_sync")
    ensure_assigned!
    raise "Level unchanged" if @level_id == new_level_id

    apply(PersonDevelopment::Events::PersonLevelChanged.new(data: {
      previous_level_id: @level_id,
      new_level_id: new_level_id,
      reason: reason
    }))
  end

  # ── Assessment Cycle Membership ──
  #
  # These commands are invoked ONLY by
  # {AssessmentCycles::SyncHandlers::PersonEnrollmentSync}, never by user code.

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

  # Leaves the given assessment cycle.
  #
  # @param cycle_id [String] UUID of the cycle being left (must match current)
  # @param reason [String] why the person is leaving
  # @raise [RuntimeError] if not in a cycle or cycle_id doesn't match
  def leave_cycle(cycle_id, reason)
    ensure_assigned!
    raise "Not currently in a cycle" if @current_cycle_id.nil?
    raise "Cycle ID does not match current cycle" unless @current_cycle_id == cycle_id

    apply(PersonDevelopment::Events::LeftAssessmentCycle.new(data: {
      cycle_id: cycle_id,
      reason: reason
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
                source: "human", seeded_from_cycle_id: nil)
    ensure_in_cycle!(cycle_id)
    ensure_individual_ratings_unfrozen!
    raise "Invalid frequency: #{frequency}" unless FREQUENCIES.include?(frequency)

    apply(PersonDevelopment::Events::SelfRated.new(data: {
      capability_stable_id: capability_stable_id,
      level_ordinal: level_ordinal,
      frequency: frequency,
      cycle_id: cycle_id,
      comment: comment,
      source: source,
      seeded_from_cycle_id: seeded_from_cycle_id
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
  def revise_self_rating(capability_stable_id, level_ordinal:, frequency:, rationale:, cycle_id:, comment: nil)
    ensure_in_cycle!(cycle_id)
    ensure_individual_ratings_unfrozen!
    raise "Invalid frequency: #{frequency}" unless FREQUENCIES.include?(frequency)
    raise "No self-rating exists for capability #{capability_stable_id} at level #{level_ordinal}" unless
      @self_ratings.key?([ capability_stable_id, level_ordinal ])

    apply(PersonDevelopment::Events::SelfRatingRevised.new(data: {
      capability_stable_id: capability_stable_id,
      level_ordinal: level_ordinal,
      frequency: frequency,
      cycle_id: cycle_id,
      comment: comment,
      rationale: rationale
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
    ensure_individual_ratings_unfrozen!
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
  # @raise [RuntimeError] if not in a cycle, wrong cycle, or invalid frequency
  def rate_as_manager(capability_stable_id, level_ordinal:, frequency:, cycle_id:, comment: nil,
                      source: "human", seeded_from_cycle_id: nil)
    ensure_in_cycle!(cycle_id)
    ensure_individual_ratings_unfrozen!
    raise "Invalid frequency: #{frequency}" unless FREQUENCIES.include?(frequency)

    apply(PersonDevelopment::Events::ManagerRated.new(data: {
      capability_stable_id: capability_stable_id,
      level_ordinal: level_ordinal,
      frequency: frequency,
      cycle_id: cycle_id,
      comment: comment,
      source: source,
      seeded_from_cycle_id: seeded_from_cycle_id
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
  # @raise [RuntimeError] if no prior manager rating for this capability at this level
  def revise_manager_rating(capability_stable_id, level_ordinal:, frequency:, rationale:, cycle_id:, comment: nil)
    ensure_in_cycle!(cycle_id)
    ensure_individual_ratings_unfrozen!
    raise "Invalid frequency: #{frequency}" unless FREQUENCIES.include?(frequency)
    raise "No manager rating exists for capability #{capability_stable_id} at level #{level_ordinal}" unless
      @manager_ratings.key?([ capability_stable_id, level_ordinal ])

    apply(PersonDevelopment::Events::ManagerRatingRevised.new(data: {
      capability_stable_id: capability_stable_id,
      level_ordinal: level_ordinal,
      frequency: frequency,
      cycle_id: cycle_id,
      comment: comment,
      rationale: rationale
    }))
  end

  # Clears a previous manager rating at a specific level.
  #
  # @param capability_stable_id [String] stable UUID of the capability
  # @param level_ordinal [Integer] the level being cleared
  # @param cycle_id [String] UUID of the cycle this rating belongs to
  # @raise [RuntimeError] if no prior manager rating for this capability at this level
  def clear_manager_rating(capability_stable_id, level_ordinal:, cycle_id:)
    ensure_in_cycle!(cycle_id)
    ensure_individual_ratings_unfrozen!
    raise "No manager rating exists for capability #{capability_stable_id} at level #{level_ordinal}" unless
      @manager_ratings.key?([ capability_stable_id, level_ordinal ])

    apply(PersonDevelopment::Events::ManagerRatingCleared.new(data: {
      capability_stable_id: capability_stable_id,
      level_ordinal: level_ordinal,
      cycle_id: cycle_id
    }))
  end

  # ── Alignment ──

  # Formally opens alignment for the current cycle.
  #
  # Once started, individual self/manager ratings are frozen — the
  # assessment becomes a shared conversation about agreed values.
  # Issued by the assessee's current direct manager (enforced by the
  # controller-side policy, not the aggregate).
  #
  # @param cycle_id [String] UUID of the cycle alignment is starting on
  # @param started_by_id [String] UUID of the person who started alignment
  # @raise [RuntimeError] if not in a cycle, wrong cycle, or already started
  def start_alignment(cycle_id, started_by_id:)
    ensure_in_cycle!(cycle_id)
    raise "Alignment already started for this cycle" if @alignment_started

    apply(PersonDevelopment::Events::AlignmentStarted.new(data: {
      cycle_id: cycle_id,
      started_by_id: started_by_id
    }))

    # Auto-align cells where self and manager explicitly recorded the same
    # frequency. Derived from the aggregate's own state (`@self_ratings`
    # and `@manager_ratings`) so we're guaranteed consistent with the
    # event stream this aggregate was loaded from — unlike a read-model
    # query, which can race with concurrent rate_* commits.
    @self_ratings.each do |key, self_freq|
      manager_freq = @manager_ratings[key]
      next unless manager_freq == self_freq

      capability_stable_id, level_ordinal = key
      apply(PersonDevelopment::Events::AssessmentAligned.new(data: {
        capability_stable_id: capability_stable_id,
        level_ordinal: level_ordinal,
        aligned_frequency: self_freq,
        cycle_id: cycle_id,
        comment: "Auto-aligned: self and manager already agreed"
      }))
    end
  end

  # Records an agreed assessment for a capability at a specific level.
  #
  # Requires alignment to have been formally started for the cycle. The
  # aligned_frequency is the authoritative view used in scoring. Agreed
  # level is derived as the highest level_ordinal where
  # aligned_frequency == "consistent".
  #
  # @param capability_stable_id [String] stable UUID of the capability
  # @param level_ordinal [Integer] the level being agreed upon
  # @param aligned_frequency [String] agreed frequency
  # @param cycle_id [String] UUID of the cycle this alignment belongs to
  # @param comment [String, nil] optional comment
  # @raise [RuntimeError] if not in a cycle, wrong cycle, alignment not started, or invalid frequency
  def align_assessment(capability_stable_id, level_ordinal:, aligned_frequency:, cycle_id:, comment: nil)
    ensure_in_cycle!(cycle_id)
    raise "Alignment has not been started for this cycle" unless @alignment_started
    raise "Alignment has been completed for this cycle" if @alignment_completed
    raise "Invalid frequency: #{aligned_frequency}" unless FREQUENCIES.include?(aligned_frequency)

    apply(PersonDevelopment::Events::AssessmentAligned.new(data: {
      capability_stable_id: capability_stable_id,
      level_ordinal: level_ordinal,
      aligned_frequency: aligned_frequency,
      cycle_id: cycle_id,
      comment: comment
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

  # Marks alignment complete for the current cycle.
  #
  # After this lands, all ratings (including aligned values) are frozen for
  # the cycle. Issued by the assessee's current direct manager (enforced by
  # the controller-side {AssessmentPolicy#complete_alignment?}).
  #
  # Snapshot point — long streams compress here.
  #
  # @param cycle_id [String] UUID of the cycle being completed
  # @param completed_by_id [String] UUID of the person completing alignment
  # @raise [RuntimeError] if not in a cycle, wrong cycle, alignment not started, or already completed
  def complete_alignment(cycle_id, completed_by_id:)
    ensure_in_cycle!(cycle_id)
    raise "Alignment has not been started for this cycle" unless @alignment_started
    raise "Alignment already completed for this cycle" if @alignment_completed

    apply(PersonDevelopment::Events::FullAlignmentCompleted.new(data: {
      cycle_id: cycle_id,
      completed_by_id: completed_by_id
    }))
  end

  # ── Evidence ──
  #
  # Evidence is qualitative context anchored to a (capability_stable_id,
  # level_ordinal) coordinate — the same coordinate as the behavioural
  # expectation it's evidence for. It does not feed scoring (see
  # ADR-10 / scoring-model.md) and does not freeze during alignment:
  # add / relink / withdraw remain available regardless of cycle status.
  # The aggregate must be assigned to a framework, but does not need to
  # be in a cycle.

  # Records a new piece of evidence.
  #
  # @param evidence_id [String] caller-supplied UUID v7 (caller owns idempotency)
  # @param capability_stable_id [String] stable UUID of the capability
  # @param level_ordinal [Integer] the level being evidenced
  # @param source [String] "self" | "manager" | "peer"
  # @param evidence_type [String] one of EVIDENCE_TYPES
  # @param content [String] the body of the evidence (required)
  # @param author_id [String] UUID of the Person recording the evidence
  # @param custom_type_label [String, nil] free text, only when evidence_type == "other"
  # @param title [String, nil] optional one-line summary
  # @param external_reference [Hash, nil] { system:, url:, external_id:, metadata: }
  # @raise [CommandError] if not assigned, evidence_id already exists, or args are invalid
  def record_evidence(evidence_id, capability_stable_id:, level_ordinal:, source:, evidence_type:,
                      content:, author_id:, custom_type_label: nil, title: nil,
                      external_reference: nil)
    ensure_assigned!
    raise CommandError, "Evidence ID already exists" if @evidence.key?(evidence_id)
    raise CommandError, "Invalid evidence source: #{source}" unless EVIDENCE_SOURCES.include?(source)
    raise CommandError, "Invalid evidence type: #{evidence_type}" unless EVIDENCE_TYPES.include?(evidence_type)
    raise CommandError, "Custom type label required when evidence_type is 'other'" if
      evidence_type == "other" && custom_type_label.to_s.strip.empty?
    raise CommandError, "Custom type label only allowed when evidence_type is 'other'" if
      evidence_type != "other" && !custom_type_label.nil? && !custom_type_label.to_s.strip.empty?
    raise CommandError, "Evidence content cannot be blank" if content.to_s.strip.empty?

    apply(PersonDevelopment::Events::EvidenceRecorded.new(data: {
      evidence_id: evidence_id,
      capability_stable_id: capability_stable_id,
      level_ordinal: level_ordinal,
      source: source,
      evidence_type: evidence_type,
      custom_type_label: custom_type_label,
      title: title,
      content: content,
      external_reference: external_reference,
      author_id: author_id
    }))
  end

  # Moves existing evidence to a different (capability, level) coordinate.
  #
  # @param evidence_id [String] UUID of the evidence to move
  # @param new_capability_stable_id [String] target capability
  # @param new_level_ordinal [Integer] target level
  # @param relinked_by_id [String] UUID of the Person making the change
  # @param rationale [String, nil] optional explanation of the move
  # @raise [CommandError] if not assigned, evidence not found, withdrawn,
  #   or target coordinate is unchanged
  def relink_evidence(evidence_id, new_capability_stable_id:, new_level_ordinal:,
                      relinked_by_id:, rationale: nil)
    ensure_assigned!
    state = @evidence[evidence_id]
    raise CommandError, "No evidence with id #{evidence_id}" unless state
    raise CommandError, "Cannot relink withdrawn evidence" if state[:status] == "withdrawn"
    if state[:capability_stable_id] == new_capability_stable_id &&
       state[:level_ordinal] == new_level_ordinal
      raise CommandError, "Evidence is already at that coordinate"
    end

    apply(PersonDevelopment::Events::EvidenceRelinked.new(data: {
      evidence_id: evidence_id,
      previous_capability_stable_id: state[:capability_stable_id],
      previous_level_ordinal: state[:level_ordinal],
      new_capability_stable_id: new_capability_stable_id,
      new_level_ordinal: new_level_ordinal,
      relinked_by_id: relinked_by_id,
      rationale: rationale
    }))
  end

  # Edits the user-correctable fields of an existing evidence item.
  #
  # Mutable: `title`, `content`, `evidence_type` (+ `custom_type_label`),
  # `external_reference`. Capability/level are owned by {#relink_evidence};
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

  # ── Comments ──
  #
  # Comments are informal-conversation context. They do not feed scoring
  # and do not freeze during alignment — posting / editing / deleting
  # remain available regardless of cycle status. V1 anchors comments to
  # (capability_stable_id, level_ordinal) cells (commentable_type
  # "assessment_cell"); future commentable types (growth_plan,
  # focus_area, check_in) will set their own identifier shape.

  COMMENT_COMMENTABLE_TYPES = [ PersonDevelopmentComment::ASSESSMENT_CELL ].freeze

  # Posts a new comment.
  #
  # @param comment_id [String] caller-supplied UUID v7 (caller owns idempotency)
  # @param commentable_type [String] currently only "assessment_cell"
  # @param body [String] comment body (required, non-blank)
  # @param author_id [String] UUID of the Person posting the comment
  # @param capability_stable_id [String, nil] required when commentable_type
  #   is "assessment_cell"
  # @param level_ordinal [Integer, nil] required when commentable_type
  #   is "assessment_cell"
  # @param parent_id [String, nil] UUID of the comment being replied to;
  #   nil for a top-level comment
  # @raise [CommandError] if not assigned, comment_id already exists, or
  #   args are invalid
  def post_comment(comment_id, commentable_type:, body:, author_id:,
                   capability_stable_id: nil, level_ordinal: nil, parent_id: nil)
    ensure_assigned!
    raise CommandError, "Comment ID already exists" if @comments.key?(comment_id)
    raise CommandError, "Invalid commentable type: #{commentable_type}" unless
      COMMENT_COMMENTABLE_TYPES.include?(commentable_type)
    raise CommandError, "Comment body cannot be blank" if body.to_s.strip.empty?

    if commentable_type == PersonDevelopmentComment::ASSESSMENT_CELL
      raise CommandError, "capability_stable_id required for assessment_cell comments" if
        capability_stable_id.to_s.strip.empty?
      raise CommandError, "level_ordinal required for assessment_cell comments" if level_ordinal.nil?
    end

    if parent_id
      parent = @comments[parent_id]
      raise CommandError, "No parent comment with id #{parent_id}" unless parent
      raise CommandError, "Cannot reply to a deleted comment" if parent[:status] == "deleted"
      # V1 thread depth is one level. The Reply UI affordance is hidden
      # on reply cards (see Comments::Card), but the aggregate is the
      # authoritative boundary — a hand-rolled API call must not be able
      # to nest deeper than the projection's render layer expects.
      raise CommandError, "Cannot reply to a reply (one-level threading)" if parent[:parent_id]
      # Replies must share their parent's anchor. Without this, a reply
      # could be posted on a different (capability, level) cell than its
      # parent, and the projection's group-by-parent thread tree would
      # show the reply orphaned from its parent's cell.
      raise CommandError, "Reply must share parent's commentable type" unless
        parent[:commentable_type] == commentable_type
      if commentable_type == PersonDevelopmentComment::ASSESSMENT_CELL
        raise CommandError, "Reply must stay on the parent's cell" unless
          parent[:capability_stable_id] == capability_stable_id &&
          parent[:level_ordinal] == level_ordinal
      end
    end

    apply(PersonDevelopment::Events::CommentPosted.new(data: {
      comment_id: comment_id,
      parent_id: parent_id,
      commentable_type: commentable_type,
      capability_stable_id: capability_stable_id,
      level_ordinal: level_ordinal,
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

    apply(PersonDevelopment::Events::CommentDeleted.new(data: {
      comment_id: comment_id,
      deleted_by_id: deleted_by_id,
      reason: reason
    }))
  end

  private

  def ensure_assigned!
    raise "Person not yet assigned to a framework" unless @assigned
  end

  def ensure_in_cycle!(expected_cycle_id)
    ensure_assigned!
    raise "Not currently in an assessment cycle" if @current_cycle_id.nil?
    raise "Cycle ID does not match current cycle" unless @current_cycle_id == expected_cycle_id
  end

  def ensure_individual_ratings_unfrozen!
    raise "Self and manager ratings are frozen during alignment" if @alignment_started
  end

  # ── Event handlers ──

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

  on PersonDevelopment::Events::JoinedAssessmentCycle do |event|
    @current_cycle_id = event.data[:cycle_id]
    @alignment_started = false
    @alignment_completed = false
    @self_ratings = {}
    @manager_ratings = {}
  end

  on PersonDevelopment::Events::LeftAssessmentCycle do |_event|
    @current_cycle_id = nil
    @alignment_started = false
    @alignment_completed = false
  end

  on PersonDevelopment::Events::AlignmentStarted do |_event|
    @alignment_started = true
  end

  on PersonDevelopment::Events::FullAlignmentCompleted do |_event|
    @alignment_completed = true
  end

  on PersonDevelopment::Events::RatingSeedSkipped do |_event|
    # Audit-only — no aggregate state to mutate.
  end

  on PersonDevelopment::Events::SelfRated do |event|
    @self_ratings[[ event.data[:capability_stable_id], event.data[:level_ordinal] ]] =
      event.data[:frequency]
  end

  on PersonDevelopment::Events::SelfRatingRevised do |event|
    @self_ratings[[ event.data[:capability_stable_id], event.data[:level_ordinal] ]] =
      event.data[:frequency]
  end

  on PersonDevelopment::Events::SelfRatingCleared do |event|
    @self_ratings.delete([ event.data[:capability_stable_id], event.data[:level_ordinal] ])
  end

  on PersonDevelopment::Events::ManagerRated do |event|
    @manager_ratings[[ event.data[:capability_stable_id], event.data[:level_ordinal] ]] =
      event.data[:frequency]
  end

  on PersonDevelopment::Events::ManagerRatingRevised do |event|
    @manager_ratings[[ event.data[:capability_stable_id], event.data[:level_ordinal] ]] =
      event.data[:frequency]
  end

  on PersonDevelopment::Events::ManagerRatingCleared do |event|
    @manager_ratings.delete([ event.data[:capability_stable_id], event.data[:level_ordinal] ])
  end

  on PersonDevelopment::Events::AssessmentAligned do |_event|
    # Alignment is persisted via projection; no aggregate state needed
  end

  on PersonDevelopment::Events::EvidenceRecorded do |event|
    @evidence[event.data[:evidence_id]] = {
      capability_stable_id: event.data[:capability_stable_id],
      level_ordinal: event.data[:level_ordinal],
      status: "active"
    }
  end

  on PersonDevelopment::Events::EvidenceRelinked do |event|
    state = @evidence[event.data[:evidence_id]]
    next unless state

    state[:capability_stable_id] = event.data[:new_capability_stable_id]
    state[:level_ordinal] = event.data[:new_level_ordinal]
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

  on PersonDevelopment::Events::CommentPosted do |event|
    @comments[event.data[:comment_id]] = {
      commentable_type: event.data[:commentable_type],
      capability_stable_id: event.data[:capability_stable_id],
      level_ordinal: event.data[:level_ordinal],
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
