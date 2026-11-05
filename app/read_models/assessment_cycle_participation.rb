# frozen_string_literal: true

# Unified read interface for a person's participation in an assessment cycle.
#
# A value object — NOT an ActiveRecord model. Composes one
# {AssessmentCycleEnrollment} (always present) and one
# {AssessmentCycleProgress} row (present once the person has joined the
# cycle on the PD side; absent if they enrolled but never joined).
#
# Read-only by design: writes go through the projections, never through
# this wrapper. See `docs/guidelines/event-sourcing.md` — every read-model
# table has exactly one projection writer; this wrapper joins the two
# tables for callers that need a unified view.
#
# @example Look up one participation
#   AssessmentCycleParticipation.find_by(cycle_id: cid, person_id: pid)
#
# @example All participations for a person
#   AssessmentCycleParticipation.for_person(person.id)
#
# @example Active participations across all cycles
#   AssessmentCycleParticipation.active
#
class AssessmentCycleParticipation
  # All possible derived statuses, drawn from the union of enrollment and progress
  # state machines. Returned by {#status}.
  STATUSES = %w[enrolled started self_complete manager_complete aligning aligned concluded withdrawn].freeze

  # Pundit policy lookup: reuse the AssessmentCyclePolicy
  def self.policy_class
    AssessmentCyclePolicy
  end

  attr_reader :enrollment, :progress

  # @param enrollment [AssessmentCycleEnrollment] required
  # @param progress [AssessmentCycleProgress, nil] optional, may be nil before
  #   `JoinedAssessmentCycle` has been handled for this (cycle, person)
  def initialize(enrollment:, progress: nil)
    raise ArgumentError, "enrollment required" if enrollment.nil?

    @enrollment = enrollment
    @progress = progress
  end

  # Wraps one enrollment + its progress (if any). Use when both are
  # already loaded in memory.
  #
  # @param enrollment [AssessmentCycleEnrollment]
  # @param progress [AssessmentCycleProgress, nil]
  # @return [AssessmentCycleParticipation]
  def self.wrap(enrollment, progress = nil)
    new(enrollment: enrollment, progress: progress)
  end

  # Finds one participation by (cycle_id, person_id). Returns nil if no
  # enrollment row exists. Loads the progress row in the same call.
  #
  # @return [AssessmentCycleParticipation, nil]
  def self.find_by(cycle_id:, person_id:)
    enrollment = AssessmentCycleEnrollment.find_by(cycle_id: cycle_id, person_id: person_id)
    return nil unless enrollment

    progress = AssessmentCycleProgress.find_by(cycle_id: cycle_id, person_id: person_id)
    new(enrollment: enrollment, progress: progress)
  end

  # All participations for a person. Returns wrapper instances, joining each
  # enrollment to its (optional) progress row in a single query.
  #
  # @param person_id [String]
  # @return [Array<AssessmentCycleParticipation>]
  def self.for_person(person_id)
    for_enrollments(AssessmentCycleEnrollment.for_person(person_id))
  end

  # Convenience scopes returning wrapper instances. Filtered on enrollment side,
  # since membership lives there.
  def self.active
    for_enrollments(AssessmentCycleEnrollment.active)
  end

  def self.withdrawn
    for_enrollments(AssessmentCycleEnrollment.withdrawn)
  end

  # Builds wrapper instances around an enrollment scope/collection, joining
  # each to its (optional) progress row in one extra query. Use this when
  # you already have an enrollment scope (e.g. from a `cycle.enrollments`
  # association) and want the unified view.
  #
  # Chains per-pair `WHERE`s with `.or` so we fetch only the exact
  # `(cycle_id, person_id)` pairs we need — PostgreSQL turns this into
  # a series of unique-index lookups. Avoids the cross-product over-fetch
  # that `where(cycle_id: [...], person_id: [...])` would produce when
  # the enrollments span multiple cycles AND multiple people, and uses
  # fully parameterized AR scopes rather than dynamic SQL strings.
  #
  # @param enrollment_scope [#to_a returning Array<AssessmentCycleEnrollment>]
  # @return [Array<AssessmentCycleParticipation>]
  def self.for_enrollments(enrollment_scope)
    enrollments = enrollment_scope.to_a
    return [] if enrollments.empty?

    pairs = enrollments.map { |e| [ e.cycle_id, e.person_id ] }.uniq
    scope = pairs.map do |cycle_id, person_id|
      AssessmentCycleProgress.where(cycle_id: cycle_id, person_id: person_id)
    end.reduce(:or)
    progress_by_pair = scope.index_by { |p| [ p.cycle_id, p.person_id ] }

    enrollments.map do |enrollment|
      new(enrollment: enrollment,
          progress: progress_by_pair[[ enrollment.cycle_id, enrollment.person_id ]])
    end
  end

  # @return [String] derived status combining enrollment + progress.
  #   Returns "withdrawn" when the enrollment is withdrawn and "concluded"
  #   when the cycle closed around the participant — both are terminal, so
  #   they win over progress state (how far they got stays readable on
  #   {#progress}). Otherwise returns the progress status if present, or
  #   "enrolled" if no progress row exists yet.
  def status
    return "withdrawn" if enrollment.status == "withdrawn"
    return "concluded" if enrollment.status == "concluded"

    lifecycle_status
  end

  # How far the participation got, whether or not it has ended: what
  # {#status} reports before the cycle closes or the person leaves. A past
  # cycle reads its alignment from this.
  #
  # @return [String] `enrolled` | `started` | `self_complete` |
  #   `manager_complete` | `aligning` | `aligned`
  def lifecycle_status
    return progress.status if progress&.status.present? && progress.status != "in_progress"
    return "started" if progress&.started_at.present?

    "enrolled"
  end

  # Whether the participation still takes self and manager ratings.
  #
  # @return [Boolean]
  def takes_ratings?
    %w[enrolled started aligning aligned].include?(status)
  end

  # @return [Boolean] whether alignment ratings can be recorded.
  def alignment_in_progress?
    status == "aligning"
  end

  # Delegated readers — membership side (enrollment).
  # `:id` / `:to_param` delegate so the wrapper round-trips through Rails
  # URL helpers (e.g. `assessment_cycle_enrollment_path(@cycle, participation)`
  # in the unenroll form) using the enrollment's UUID. Enrollment is the
  # always-present side; routing for participant-targeted actions hits the
  # enrollments controller.
  delegate :id, :to_param,
           :cycle_id, :person_id, :tenant_id, :cycle, :person,
           :enrolled_at, :withdrawn_at, :withdrawal_reason,
           to: :enrollment

  # Delegated readers — journey side (progress). `allow_nil: true` returns
  # nil from every reader when the progress row is absent, so callers don't
  # have to nil-check the wrapper.
  delegate :started_at, :self_completed_at, :manager_completed_at,
           :alignment_started_at, :alignment_started_by_id, :alignment_started_by,
           :aligned_at, :aligned_by_id, :aligned_by,
           to: :progress, allow_nil: true
end
