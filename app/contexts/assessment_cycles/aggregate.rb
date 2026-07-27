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
    @framework_version = nil          # version at define time (lower bound)
    @latest_framework_version = nil   # highest version this cycle has been rolled through
    @name = nil
    @cycle_type = nil
    @planned_end_at = nil
    @status = :new
    @enrolled_person_ids = Set.new
    @enrolled_roles = {}  # person_id => { role_id:, level_id: } — assessed role/level per participant
  end

  # Defines a new assessment cycle.
  #
  # @param cycle_id [String] UUID for the cycle
  # @param framework_id [String] UUID of the framework being assessed
  # @param name [String] display name (e.g. "Q1 2026 Review")
  # @param cycle_type [String] one of: regular, performance_review, promotion_review
  # @param framework_version [Integer] the framework version to freeze against
  # @param defined_by [String, nil] optional person_id / tenant_user_id of the creator
  # @param planned_end_at [String, Date, nil] soft target completion date
  # @raise [RuntimeError] if already defined or invalid cycle_type
  def define(cycle_id, framework_id, name, cycle_type, framework_version, defined_by: nil, planned_end_at: nil)
    raise "Cycle already defined" unless @status == :new
    raise "Invalid cycle type: #{cycle_type}" unless CYCLE_TYPES.include?(cycle_type)

    apply(AssessmentCycles::Events::CycleDefined.new(data: {
      cycle_id: cycle_id,
      framework_id: framework_id,
      framework_version: framework_version,
      name: name,
      cycle_type: cycle_type,
      defined_by: defined_by,
      planned_end_at: normalize_planned_end(planned_end_at)
    }))
  end

  # Renames the cycle. No-op (no event emitted) if the new name matches
  # the current name.
  #
  # @param new_name [String]
  # @param updated_by [String, nil]
  # @raise [RuntimeError] if cycle not open or new_name is blank
  def rename(new_name, updated_by: nil)
    ensure_open!
    raise "Name can't be blank" if new_name.to_s.strip.empty?
    return if @name == new_name

    apply(AssessmentCycles::Events::CycleRenamed.new(data: {
      cycle_id: @cycle_id,
      new_name: new_name,
      updated_by: updated_by
    }))
  end

  # Changes the cycle type.
  #
  # @param new_cycle_type [String] one of {CYCLE_TYPES}
  # @param updated_by [String, nil]
  # @raise [RuntimeError] if cycle not open or invalid cycle_type
  def change_type(new_cycle_type, updated_by: nil)
    ensure_open!
    raise "Invalid cycle type: #{new_cycle_type}" unless CYCLE_TYPES.include?(new_cycle_type)
    return if @cycle_type == new_cycle_type

    apply(AssessmentCycles::Events::CycleTypeChanged.new(data: {
      cycle_id: @cycle_id,
      new_cycle_type: new_cycle_type,
      updated_by: updated_by
    }))
  end

  # Sets, changes, or clears the planned end date. Pass `nil` to clear.
  #
  # @param planned_end_at [String, Date, nil]
  # @param updated_by [String, nil]
  # @raise [RuntimeError] if cycle not open
  def set_planned_end(planned_end_at, updated_by: nil)
    ensure_open!
    normalized = normalize_planned_end(planned_end_at)
    return if @planned_end_at == normalized

    apply(AssessmentCycles::Events::CyclePlannedEndSet.new(data: {
      cycle_id: @cycle_id,
      planned_end_at: normalized,
      updated_by: updated_by
    }))
  end

  # Enrolls a person in the cycle.
  #
  # @param person_id [String] UUID of the person to enroll
  # @param enrolled_by [String, nil] optional person_id / tenant_user_id of the enroller
  # @param role_id [String, nil] role the person is assessed against (snapshot)
  # @param level_id [String, nil] level the person is assessed against (snapshot)
  # @raise [RuntimeError] if cycle not open or person already enrolled
  def enroll(person_id, enrolled_by: nil, role_id: nil, level_id: nil)
    ensure_open!
    raise "Person already enrolled" if @enrolled_person_ids.include?(person_id)

    apply(AssessmentCycles::Events::PersonEnrolled.new(data: {
      cycle_id: @cycle_id,
      person_id: person_id,
      framework_id: @framework_id,
      framework_version: @framework_version,
      enrolled_by: enrolled_by,
      role_id: role_id,
      level_id: level_id
    }))
  end

  # Re-snapshots an enrolled participant's assessed role/level mid-cycle.
  #
  # Issued by {AssessmentCycles::SyncHandlers::ParticipantRoleSync} when a
  # PersonLevelChanged / PersonRoleChanged lands while this cycle is open.
  # No-op (no event) when role+level are unchanged, so repeat HRIS syncs
  # don't emit redundant events.
  #
  # @param person_id [String] UUID of the enrolled participant
  # @param role_id [String] new role being assessed against
  # @param level_id [String] new level being assessed against
  # @param reason [String] why the change occurred
  # @raise [RuntimeError] if cycle not open or person not enrolled
  def update_participant_role(person_id, role_id, level_id, reason: "hris_sync")
    ensure_open!
    raise "Person not enrolled" unless @enrolled_person_ids.include?(person_id)

    current = @enrolled_roles[person_id]
    return if current && current[:role_id] == role_id && current[:level_id] == level_id

    apply(AssessmentCycles::Events::ParticipantRoleLevelChanged.new(data: {
      cycle_id: @cycle_id,
      person_id: person_id,
      role_id: role_id,
      level_id: level_id,
      reason: reason
    }))
  end

  # Removes a person from the cycle.
  #
  # The reason is free text from the unenrolling admin, EXCEPT the reserved
  # "cycle_closed" — that would masquerade a person-scoped removal as a cycle
  # conclusion downstream, so it is rejected here at the entry boundary
  # (before any event is applied) with a message fit for the admin's flash.
  #
  # @param person_id [String] UUID of the person to unenroll
  # @param reason [String] why the person is being removed
  # @param unenrolled_by [String, nil] optional person_id / tenant_user_id
  # @raise [RuntimeError] if cycle not open, person not enrolled, or the
  #   reason is the reserved "cycle_closed"
  def unenroll(person_id, reason, unenrolled_by: nil)
    ensure_open!
    if reason.to_s.strip == "cycle_closed"
      raise "\"cycle_closed\" is a reserved reason — describe why this person is being removed instead"
    end
    raise "Person not enrolled" unless @enrolled_person_ids.include?(person_id)

    apply(AssessmentCycles::Events::PersonUnenrolled.new(data: {
      cycle_id: @cycle_id,
      person_id: person_id,
      framework_id: @framework_id,
      reason: reason,
      unenrolled_by: unenrolled_by
    }))
  end

  # Rolls the cycle forward to a newly-published framework version.
  #
  # Called by {AssessmentCycles::SyncHandlers::FrameworkVersionRollSync}
  # in the same transaction as the originating
  # {Frameworks::Events::FrameworkVersionPublished}. Records the upper
  # bound of the version range this cycle has been open across, so
  # views and reports can express the full span.
  #
  # No-op (no event emitted) when the cycle is closed (range is
  # frozen) or when `new_version` is at or below the highest version
  # already recorded — making predeploy replay safe.
  #
  # @param new_version [Integer] the newly published framework version
  def roll_framework_version(new_version)
    return if @status != :open
    return if @latest_framework_version && @latest_framework_version >= new_version

    apply(AssessmentCycles::Events::FrameworkVersionRolled.new(data: {
      cycle_id: @cycle_id,
      framework_id: @framework_id,
      new_version: new_version
    }))
  end

  # Closes the cycle. Every currently-enrolled person's participation
  # concludes — {PersonDevelopment::Events::AssessmentCycleConcluded} on
  # their PersonDev streams (via the cross-stream sync handler), never a
  # removal: they remain part of the cycle's historical cohort.
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

  # Coerce input to an ISO 8601 date string ("YYYY-MM-DD") for stable event
  # payloads. Returns nil for blank input.
  def normalize_planned_end(value)
    return nil if value.nil?
    return nil if value.respond_to?(:empty?) && value.empty?

    case value
    when Date then value.iso8601
    when String then Date.parse(value).iso8601
    else value.to_date.iso8601
    end
  end

  # ── Event handlers ──

  on AssessmentCycles::Events::CycleDefined do |event|
    @cycle_id = event.data[:cycle_id]
    @framework_id = event.data[:framework_id]
    @framework_version = event.data[:framework_version]
    @latest_framework_version = event.data[:framework_version]
    @name = event.data[:name]
    @cycle_type = event.data[:cycle_type]
    @planned_end_at = event.data[:planned_end_at]
    @status = :open
  end

  on AssessmentCycles::Events::FrameworkVersionRolled do |event|
    @latest_framework_version = event.data[:new_version]
  end

  on AssessmentCycles::Events::CycleRenamed do |event|
    @name = event.data[:new_name]
  end

  on AssessmentCycles::Events::CycleTypeChanged do |event|
    @cycle_type = event.data[:new_cycle_type]
  end

  on AssessmentCycles::Events::CyclePlannedEndSet do |event|
    @planned_end_at = event.data[:planned_end_at]
  end

  on AssessmentCycles::Events::PersonEnrolled do |event|
    @enrolled_person_ids << event.data[:person_id]
    @enrolled_roles[event.data[:person_id]] =
      { role_id: event.data[:role_id], level_id: event.data[:level_id] }
  end

  on AssessmentCycles::Events::PersonUnenrolled do |event|
    @enrolled_person_ids.delete(event.data[:person_id])
    @enrolled_roles.delete(event.data[:person_id])
  end

  on AssessmentCycles::Events::ParticipantRoleLevelChanged do |event|
    @enrolled_roles[event.data[:person_id]] =
      { role_id: event.data[:role_id], level_id: event.data[:level_id] }
  end

  on AssessmentCycles::Events::CycleClosed do |_event|
    @status = :closed
    @enrolled_person_ids.clear
    @enrolled_roles.clear
  end
end
