# frozen_string_literal: true

require "set"

# Event-sourced aggregate for an assessment cycle.
#
# One RES stream per cycle: tenant-{tenant_id}/AssessmentCycle-{cycle_id}.
#
# A cycle is the shared entity many people are enrolled into. Command
# methods validate invariants and apply events; event handlers update
# internal state. Cross-stream propagation to PersonDevelopment happens
# via a separate synchronous subscriber (see
# {AssessmentCycles::SyncHandlers::PersonEnrollmentSync}), NOT from
# inside this aggregate.
#
class AssessmentCycles::Aggregate
  include AggregateRoot

  CYCLE_TYPES = %w[regular performance_review promotion_review].freeze

  def initialize
    @cycle_id = nil
    @framework_id = nil
    @framework_version = nil
    @name = nil
    @cycle_type = nil
    @status = :new
    @enrolled_person_ids = Set.new
  end

  # Defines a new assessment cycle.
  #
  # @param cycle_id [String] UUID for the cycle
  # @param framework_id [String] UUID of the framework being assessed
  # @param name [String] display name (e.g. "Q1 2026 Review")
  # @param cycle_type [String] one of: regular, performance_review, promotion_review
  # @param framework_version [Integer] the framework version to freeze against
  # @param defined_by [String, nil] optional person_id / tenant_user_id of the creator
  # @raise [RuntimeError] if already defined or invalid cycle_type
  def define(cycle_id, framework_id, name, cycle_type, framework_version, defined_by: nil)
    raise "Cycle already defined" unless @status == :new
    raise "Invalid cycle type: #{cycle_type}" unless CYCLE_TYPES.include?(cycle_type)

    apply(AssessmentCycles::Events::CycleDefined.new(data: {
      cycle_id: cycle_id,
      framework_id: framework_id,
      framework_version: framework_version,
      name: name,
      cycle_type: cycle_type,
      defined_by: defined_by
    }))
  end

  # Enrolls a person in the cycle.
  #
  # @param person_id [String] UUID of the person to enroll
  # @param enrolled_by [String, nil] optional person_id / tenant_user_id of the enroller
  # @raise [RuntimeError] if cycle not open or person already enrolled
  def enroll(person_id, enrolled_by: nil)
    ensure_open!
    raise "Person already enrolled" if @enrolled_person_ids.include?(person_id)

    apply(AssessmentCycles::Events::PersonEnrolled.new(data: {
      cycle_id: @cycle_id,
      person_id: person_id,
      framework_id: @framework_id,
      framework_version: @framework_version,
      enrolled_by: enrolled_by
    }))
  end

  # Removes a person from the cycle.
  #
  # @param person_id [String] UUID of the person to unenroll
  # @param reason [String] why the person is being removed
  # @param unenrolled_by [String, nil] optional person_id / tenant_user_id
  # @raise [RuntimeError] if cycle not open or person not enrolled
  def unenroll(person_id, reason, unenrolled_by: nil)
    ensure_open!
    raise "Person not enrolled" unless @enrolled_person_ids.include?(person_id)

    apply(AssessmentCycles::Events::PersonUnenrolled.new(data: {
      cycle_id: @cycle_id,
      person_id: person_id,
      framework_id: @framework_id,
      reason: reason,
      unenrolled_by: unenrolled_by
    }))
  end

  # Closes the cycle. All currently-enrolled persons are implicitly removed
  # from the cycle via {LeftAssessmentCycle} events on their PersonDev streams
  # (handled by the cross-stream sync handler).
  #
  # @param closed_by [String, nil] optional person_id / tenant_user_id
  # @raise [RuntimeError] if cycle not open
  def close(closed_by: nil)
    ensure_open!

    apply(AssessmentCycles::Events::CycleClosed.new(data: {
      cycle_id: @cycle_id,
      framework_id: @framework_id,
      enrolled_person_ids: @enrolled_person_ids.to_a,
      closed_by: closed_by
    }))
  end

  private

  def ensure_open!
    raise "Cycle not defined" if @status == :new
    raise "Cycle is closed" if @status == :closed
  end

  # ── Event handlers ──

  on AssessmentCycles::Events::CycleDefined do |event|
    @cycle_id = event.data[:cycle_id]
    @framework_id = event.data[:framework_id]
    @framework_version = event.data[:framework_version]
    @name = event.data[:name]
    @cycle_type = event.data[:cycle_type]
    @status = :open
  end

  on AssessmentCycles::Events::PersonEnrolled do |event|
    @enrolled_person_ids << event.data[:person_id]
  end

  on AssessmentCycles::Events::PersonUnenrolled do |event|
    @enrolled_person_ids.delete(event.data[:person_id])
  end

  on AssessmentCycles::Events::CycleClosed do |_event|
    @status = :closed
    @enrolled_person_ids.clear
  end
end
