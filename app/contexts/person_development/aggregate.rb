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

  FREQUENCIES = %w[none some occasional consistent].freeze

  def initialize
    @person_id = nil
    @framework_id = nil
    @role_id = nil
    @level_id = nil
    @assigned = false
    @current_cycle_id = nil
    @self_ratings = {}   # [stable_id, level_ordinal] => frequency
    @manager_ratings = {} # [stable_id, level_ordinal] => frequency
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
  def rate_self(capability_stable_id, level_ordinal:, frequency:, cycle_id:, comment: nil)
    ensure_in_cycle!(cycle_id)
    raise "Invalid frequency: #{frequency}" unless FREQUENCIES.include?(frequency)

    apply(PersonDevelopment::Events::SelfRated.new(data: {
      capability_stable_id: capability_stable_id,
      level_ordinal: level_ordinal,
      frequency: frequency,
      cycle_id: cycle_id,
      comment: comment
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
  def rate_as_manager(capability_stable_id, level_ordinal:, frequency:, cycle_id:, comment: nil)
    ensure_in_cycle!(cycle_id)
    raise "Invalid frequency: #{frequency}" unless FREQUENCIES.include?(frequency)

    apply(PersonDevelopment::Events::ManagerRated.new(data: {
      capability_stable_id: capability_stable_id,
      level_ordinal: level_ordinal,
      frequency: frequency,
      cycle_id: cycle_id,
      comment: comment
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
    raise "No manager rating exists for capability #{capability_stable_id} at level #{level_ordinal}" unless
      @manager_ratings.key?([ capability_stable_id, level_ordinal ])

    apply(PersonDevelopment::Events::ManagerRatingCleared.new(data: {
      capability_stable_id: capability_stable_id,
      level_ordinal: level_ordinal,
      cycle_id: cycle_id
    }))
  end

  # ── Alignment ──

  # Records an agreed assessment for a capability at a specific level.
  #
  # The aligned_frequency is the authoritative view used in scoring.
  # Agreed level is derived as the highest level_ordinal where
  # aligned_frequency == "consistent".
  #
  # @param capability_stable_id [String] stable UUID of the capability
  # @param level_ordinal [Integer] the level being agreed upon
  # @param aligned_frequency [String] agreed frequency
  # @param cycle_id [String] UUID of the cycle this alignment belongs to
  # @param comment [String, nil] optional comment
  # @raise [RuntimeError] if not in a cycle, wrong cycle, or invalid frequency
  def align_assessment(capability_stable_id, level_ordinal:, aligned_frequency:, cycle_id:, comment: nil)
    ensure_in_cycle!(cycle_id)
    raise "Invalid frequency: #{aligned_frequency}" unless FREQUENCIES.include?(aligned_frequency)

    apply(PersonDevelopment::Events::AssessmentAligned.new(data: {
      capability_stable_id: capability_stable_id,
      level_ordinal: level_ordinal,
      aligned_frequency: aligned_frequency,
      cycle_id: cycle_id,
      comment: comment
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
    @self_ratings = {}
    @manager_ratings = {}
  end

  on PersonDevelopment::Events::LeftAssessmentCycle do |_event|
    @current_cycle_id = nil
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
end
