# frozen_string_literal: true

# Handles commands for the PersonDevelopment aggregate.
#
# Loads the aggregate via the repository, executes the command,
# and stores resulting events.
#
class PersonDevelopment::CommandHandler
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
  def assign_to_framework(person_id, framework_id, role_id, level_id)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.assign_to_framework(person_id, framework_id, role_id, level_id)
    end
  end

  # Changes a person's role (and level) within their current framework.
  #
  # @param person_id [String] UUID of the person
  # @param framework_id [String] UUID of the framework
  # @param new_role_id [String] UUID of the new role
  # @param new_level_id [String] UUID of the new level
  # @param reason [String] why the change occurred
  def change_person_role(person_id, framework_id, new_role_id, new_level_id, reason: "hris_sync")
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.change_role(new_role_id, new_level_id, reason: reason)
    end
  end

  # Changes a person's level within the same role (promotion).
  #
  # @param person_id [String] UUID of the person
  # @param framework_id [String] UUID of the framework
  # @param new_level_id [String] UUID of the new level
  # @param reason [String] why the change occurred
  def change_person_level(person_id, framework_id, new_level_id, reason: "hris_sync")
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.change_level(new_level_id, reason: reason)
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

  # Removes the person from their current assessment cycle.
  #
  # Called ONLY by {AssessmentCycles::SyncHandlers::PersonEnrollmentSync}
  # in response to a PersonUnenrolled or CycleClosed event — never by controllers.
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
  def rate_self(person_id, framework_id, capability_stable_id,
                level_ordinal:, frequency:, cycle_id:, comment: nil,
                source: "human", seeded_from_cycle_id: nil)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.rate_self(capability_stable_id, level_ordinal: level_ordinal,
        frequency: frequency, cycle_id: cycle_id, comment: comment,
        source: source, seeded_from_cycle_id: seeded_from_cycle_id)
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
  def revise_self_rating(person_id, framework_id, capability_stable_id,
                         level_ordinal:, frequency:, rationale:, cycle_id:, comment: nil)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.revise_self_rating(capability_stable_id, level_ordinal: level_ordinal,
        frequency: frequency, rationale: rationale, cycle_id: cycle_id, comment: comment)
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
  def rate_as_manager(person_id, framework_id, capability_stable_id,
                      level_ordinal:, frequency:, cycle_id:, comment: nil,
                      source: "human", seeded_from_cycle_id: nil)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.rate_as_manager(capability_stable_id, level_ordinal: level_ordinal,
        frequency: frequency, cycle_id: cycle_id, comment: comment,
        source: source, seeded_from_cycle_id: seeded_from_cycle_id)
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
  def revise_manager_rating(person_id, framework_id, capability_stable_id,
                            level_ordinal:, frequency:, rationale:, cycle_id:, comment: nil)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.revise_manager_rating(capability_stable_id, level_ordinal: level_ordinal,
        frequency: frequency, rationale: rationale, cycle_id: cycle_id, comment: comment)
    end
  end

  # Clears a previous manager rating.
  #
  # @param person_id [String] UUID of the person being rated
  # @param framework_id [String] UUID of the framework
  # @param capability_stable_id [String] stable UUID of the capability
  # @param level_ordinal [Integer] the level being cleared
  # @param cycle_id [String] UUID of the cycle this rating belongs to
  def clear_manager_rating(person_id, framework_id, capability_stable_id, level_ordinal:, cycle_id:)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.clear_manager_rating(capability_stable_id, level_ordinal: level_ordinal, cycle_id: cycle_id)
    end
  end

  # Formally opens alignment for a person's current assessment cycle.
  #
  # Once started, individual self/manager ratings are frozen for the cycle.
  # Issued only by the assessee's current direct manager (enforced by
  # the controller-side {AssessmentPolicy#start_alignment?}).
  #
  # The aggregate additionally auto-emits an AssessmentAligned event for
  # every (capability × level) cell where both perspectives explicitly
  # rated the same frequency. The conversation then focuses on
  # disagreements and unrated cells. Default-fallback agreements (where
  # one or both perspectives never recorded an explicit value) do NOT
  # auto-align — only deliberate, recorded agreement counts.
  #
  # @param person_id [String] UUID of the person being assessed
  # @param framework_id [String] UUID of the framework
  # @param cycle_id [String] UUID of the cycle alignment is starting on
  # @param started_by_id [String] UUID of the person who started alignment
  def start_alignment(person_id, framework_id, cycle_id, started_by_id:)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.start_alignment(cycle_id, started_by_id: started_by_id)
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
  def align_assessment(person_id, framework_id, capability_stable_id,
                       level_ordinal:, aligned_frequency:, cycle_id:, comment: nil)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.align_assessment(capability_stable_id, level_ordinal: level_ordinal,
        aligned_frequency: aligned_frequency, cycle_id: cycle_id, comment: comment)
    end
  end

  # Marks alignment complete for the current cycle.
  #
  # After this lands, all ratings (including aligned values) are frozen.
  # Issued only by the assessee's current direct manager (enforced by
  # the controller-side {AssessmentPolicy#complete_alignment?}).
  #
  # @param person_id [String] UUID of the person being assessed
  # @param framework_id [String] UUID of the framework
  # @param cycle_id [String] UUID of the cycle being completed
  # @param completed_by_id [String] UUID of the person completing alignment
  def complete_alignment(person_id, framework_id, cycle_id, completed_by_id:)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.complete_alignment(cycle_id, completed_by_id: completed_by_id)
    end
  end

  # Seeds the current cycle's ratings from a prior cycle's aligned values.
  #
  # For each (capability, level) where the prior cycle reached an aligned
  # frequency, emits both a SelfRated and ManagerRated event with
  # `source: "seeded"` and `seeded_from_cycle_id: <prior>`. The new cycle
  # starts with both perspectives pre-populated so the conversation
  # opens with "this is where we agreed you were last cycle — confirm
  # or update."
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
    # Refuse to seed unless the prior cycle actually reached the `aligned`
    # lifecycle state — i.e. the manager fired FullAlignmentCompleted on it.
    # A cycle that is still merely `aligning` may have a few aligned cells
    # from a partial conversation, but those aren't a valid carry-forward
    # baseline. The participant's `aligned_at` is set only by
    # FullAlignmentCompleted and survives subsequent cycle closure.
    prior_completed = AssessmentCycleParticipant
      .where(cycle_id: prior_cycle_id, person_id: person_id)
      .where.not(aligned_at: nil)
      .exists?

    return { seeded: 0, skipped: [], seeded_by_id: seeded_by_id } unless prior_completed

    prior_aligned = AssessmentLevelRating
      .for_person(person_id)
      .for_framework(framework_id)
      .for_cycle(prior_cycle_id)
      .aligned

    valid_stable_ids = FrameworkState::Capability
      .joins(:category)
      .where(framework_capability_categories: { framework_id: framework_id })
      .pluck(:stable_id)
      .to_set

    # Idempotency: any (cap, level) pair we've already seeded into the new
    # cycle — by an earlier run, or by a manual rate during enrolment — is
    # left alone. Re-running the seed is a no-op for those pairs.
    already_seeded_pairs = AssessmentLevelRating
      .for_person(person_id)
      .for_framework(framework_id)
      .for_cycle(current_cycle_id)
      .pluck(:capability_stable_id, :level_ordinal)
      .to_set

    seeded = 0
    skipped = []

    # Load the aggregate ONCE, emit all seed + skip events inside a
    # single with_person_development block. Avoids per-event aggregate
    # replays.
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      prior_aligned.each do |rating|
        stable_id = rating.capability_stable_id
        next if already_seeded_pairs.include?([ stable_id, rating.level_ordinal ])

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

        aggregate.rate_self(stable_id,
          level_ordinal: rating.level_ordinal,
          frequency: rating.aligned_frequency,
          cycle_id: current_cycle_id,
          comment: "Seeded from prior cycle",
          source: "seeded",
          seeded_from_cycle_id: prior_cycle_id)
        aggregate.rate_as_manager(stable_id,
          level_ordinal: rating.level_ordinal,
          frequency: rating.aligned_frequency,
          cycle_id: current_cycle_id,
          comment: "Seeded from prior cycle",
          source: "seeded",
          seeded_from_cycle_id: prior_cycle_id)
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
  def record_evidence(person_id, framework_id, evidence_id,
                      capability_stable_id:, level_ordinal:, source:, evidence_type:,
                      content:, author_id:, custom_type_label: nil, title: nil,
                      external_reference: nil)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.record_evidence(evidence_id,
        capability_stable_id: capability_stable_id, level_ordinal: level_ordinal,
        source: source, evidence_type: evidence_type, content: content,
        author_id: author_id, custom_type_label: custom_type_label,
        title: title, external_reference: external_reference)
    end
  end

  # Moves existing evidence to a new (capability, level) coordinate.
  #
  # @param person_id [String] UUID of the person
  # @param framework_id [String] UUID of the framework
  # @param evidence_id [String] UUID of the evidence to move
  # @param new_capability_stable_id [String] target capability
  # @param new_level_ordinal [Integer] target level
  # @param relinked_by_id [String] UUID of the Person making the change
  # @param rationale [String, nil] optional explanation
  def relink_evidence(person_id, framework_id, evidence_id,
                      new_capability_stable_id:, new_level_ordinal:,
                      relinked_by_id:, rationale: nil)
    @repository.with_person_development(person_id, framework_id) do |aggregate|
      aggregate.relink_evidence(evidence_id,
        new_capability_stable_id: new_capability_stable_id,
        new_level_ordinal: new_level_ordinal,
        relinked_by_id: relinked_by_id, rationale: rationale)
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
end
