# frozen_string_literal: true

# Event-sourced aggregate for a person's development journey within a framework.
#
# One RES stream per person per framework:
# tenant-{tenant_id}/PersonDev-{person_id}-{framework_id}.
#
# An "assessment" is a projection derived from this stream — not a separate entity.
#
class PersonDevelopment::Aggregate
  include AggregateRoot

  CYCLE_TYPES = %w[regular performance_review promotion_review].freeze

  def initialize
    @person_id = nil
    @framework_id = nil
    @role_id = nil
    @level_id = nil
    @assigned = false
    @current_cycle_id = nil
    @cycle_open = false
    @self_ratings = {} # capability_stable_id => level_id
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

  # ── Assessment Cycles ──

  # Opens a new assessment cycle.
  #
  # @param cycle_id [String] UUID for the new cycle
  # @param cycle_name [String] display name (e.g. "Q1 2026")
  # @param cycle_type [String] one of: regular, performance_review, promotion_review
  # @param framework_version [Integer] the framework version this cycle assesses against
  # @raise [RuntimeError] if not assigned or cycle already open
  def open_assessment_cycle(cycle_id, cycle_name, cycle_type, framework_version)
    ensure_assigned!
    raise "Assessment cycle already open" if @cycle_open
    raise "Invalid cycle type: #{cycle_type}" unless CYCLE_TYPES.include?(cycle_type)

    apply(PersonDevelopment::Events::AssessmentCycleOpened.new(data: {
      cycle_id: cycle_id,
      cycle_name: cycle_name,
      cycle_type: cycle_type,
      framework_version: framework_version
    }))
  end

  # Completes the current assessment cycle.
  #
  # @param cycle_id [String] UUID of the cycle to complete
  # @raise [RuntimeError] if no cycle open or wrong cycle ID
  def complete_assessment_cycle(cycle_id)
    ensure_assigned!
    raise "No assessment cycle open" unless @cycle_open
    raise "Cycle ID does not match open cycle" unless @current_cycle_id == cycle_id

    apply(PersonDevelopment::Events::AssessmentCycleCompleted.new(data: {
      cycle_id: cycle_id
    }))
  end

  # ── Self-Rating ──

  # Records a self-rating for a capability.
  #
  # @param capability_stable_id [String] stable UUID of the capability
  # @param level_id [String] UUID of the level the person rates themselves at
  # @param comment [String, nil] optional rationale
  # @raise [RuntimeError] if no cycle open
  def rate_self(capability_stable_id, level_id, comment: nil)
    ensure_cycle_open!

    apply(PersonDevelopment::Events::SelfRated.new(data: {
      capability_stable_id: capability_stable_id,
      level_id: level_id,
      comment: comment
    }))
  end

  # Revises a previous self-rating.
  #
  # @param capability_stable_id [String] stable UUID of the capability
  # @param new_level_id [String] UUID of the revised level
  # @param rationale [String] reason for the change
  # @param comment [String, nil] optional comment
  # @raise [RuntimeError] if no prior self-rating for this capability
  def revise_self_rating(capability_stable_id, new_level_id, rationale:, comment: nil)
    ensure_cycle_open!
    raise "No self-rating exists for capability #{capability_stable_id}" unless @self_ratings.key?(capability_stable_id)

    apply(PersonDevelopment::Events::SelfRatingRevised.new(data: {
      capability_stable_id: capability_stable_id,
      new_level_id: new_level_id,
      comment: comment,
      rationale: rationale
    }))
  end

  private

  def ensure_assigned!
    raise "Person not yet assigned to a framework" unless @assigned
  end

  def ensure_cycle_open!
    ensure_assigned!
    raise "No assessment cycle open" unless @cycle_open
  end

  # ── Event handlers ──

  on PersonDevelopment::Events::PersonAssignedToFramework do |event|
    @person_id = event.data[:person_id]
    @framework_id = event.data[:framework_id]
    @role_id = event.data[:role_id]
    @level_id = event.data[:level_id]
    @assigned = true
  end

  on PersonDevelopment::Events::AssessmentCycleOpened do |event|
    @current_cycle_id = event.data[:cycle_id]
    @cycle_open = true
    @self_ratings = {} # Reset ratings for new cycle
  end

  on PersonDevelopment::Events::AssessmentCycleCompleted do |_event|
    @current_cycle_id = nil
    @cycle_open = false
  end

  on PersonDevelopment::Events::SelfRated do |event|
    @self_ratings[event.data[:capability_stable_id]] = event.data[:level_id]
  end

  on PersonDevelopment::Events::SelfRatingRevised do |event|
    @self_ratings[event.data[:capability_stable_id]] = event.data[:new_level_id]
  end
end
