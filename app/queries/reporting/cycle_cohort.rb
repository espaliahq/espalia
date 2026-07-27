# frozen_string_literal: true

# Aggregates how an assessment cycle is progressing across a set of
# participants — for the Home cohort card (summary mode) and the cohort
# drill-down view (full mode).
#
# Read-only and compute-on-read: no new tables, no projection. All queries are
# tenant-scoped via the read models' `acts_as_tenant`. Callers pass the cycle
# and an optional `scope_person_ids` (a manager's subtree, from
# {Person#all_reports}); `nil` means the whole cycle (admin/HR).
#
# **Completion semantics** (ADR-19 + the cohort plan): there is no explicit
# "I'm done" milestone, so self/manager completion is *derived from coverage* —
# a participant is "self-done" when they have a self rating for every capability
# bound to their **assessed role** (enrollment snapshot) at their **assessed
# level**. Aligned is the one explicit milestone (progress status `aligned`).
#
# **At-risk** = not yet aligned AND (past the cycle's `planned_end_at`, OR no
# activity for {AT_RISK_IDLE_DAYS} days). "Activity" is the latest of enrolment,
# lifecycle, and rating timestamps.
#
# Privacy: this query exposes only counts/status — never rating *values*. The
# drill-down view renders individual funnel position, never scores.
class Reporting::CycleCohort
  AT_RISK_IDLE_DAYS = 14

  # The Self → Manager → Aligned funnel as head counts (people at 100% coverage,
  # plus the explicit aligned milestone).
  Funnel = Data.define(:enrolled, :self_done, :manager_done, :aligned) do
    def pct(count) = enrolled.zero? ? 0 : (count.to_f / enrolled * 100).round
    def self_pct = pct(self_done)
    def manager_pct = pct(manager_done)
    def aligned_pct = pct(aligned)
  end

  # One participant's progress. Carries no rating values — only coverage counts
  # and lifecycle status.
  Participant = Data.define(
    :person_id, :name, :manager_id, :role_id, :role_name, :level_ordinal,
    :status, :expected_count, :self_count, :manager_count,
    :self_done, :manager_done, :aligned, :at_risk, :last_activity_at
  )

  # A grouping bucket (by manager / role / level) with its own funnel.
  Group = Data.define(:key, :label, :total, :funnel, :at_risk_count)

  Result = Data.define(
    :cycle, :total, :funnel, :status_counts, :at_risk_count,
    :participants, :groups, :top_lagging_group
  ) do
    def any? = total.positive?
  end

  # @param cycle [AssessmentCycle]
  # @param scope_person_ids [Array<String>, nil] restrict to these people
  #   (a manager's subtree); nil = the whole cycle
  # @param mode [Symbol] :summary (card) or :full (drill-down view)
  # @param now [Time] injectable clock for at-risk calculations
  def initialize(cycle:, scope_person_ids: nil, mode: :full, now: Time.current)
    @cycle = cycle
    @scope_person_ids = scope_person_ids
    @mode = mode
    @now = now
  end

  # @return [Reporting::CycleCohort::Result]
  def call
    participants = build_participants
    manager_groups = build_manager_groups(participants)

    Result.new(
      cycle: @cycle,
      total: participants.size,
      funnel: build_funnel(participants),
      status_counts: participants.group_by(&:status).transform_values(&:size),
      at_risk_count: participants.count(&:at_risk),
      participants: @mode == :full ? participants : [],
      groups: @mode == :full ? full_groups(participants, manager_groups) : {},
      top_lagging_group: top_lagging(manager_groups)
    )
  end

  private

  def build_participants
    enrollments = AssessmentCycleEnrollment.active.where(cycle_id: @cycle.cycle_id)
    enrollments = enrollments.where(person_id: @scope_person_ids) if @scope_person_ids
    enrollments = enrollments.to_a
    return [] if enrollments.empty?

    person_ids = enrollments.map(&:person_id)
    role_ids = enrollments.filter_map(&:role_id).uniq

    progress = AssessmentCycleProgress
      .where(cycle_id: @cycle.cycle_id, person_id: person_ids).index_by(&:person_id)
    people = Person.where(id: person_ids).index_by(&:id)
    roles = FrameworkState::Role.where(role_id: role_ids).index_by(&:role_id)
    expected = expected_capability_counts(role_ids)
    coverage = coverage_by_person(person_ids)

    enrollments.map do |enrollment|
      build_participant(enrollment, progress, people, roles, expected, coverage)
    end
  end

  def build_participant(enrollment, progress, people, roles, expected, coverage)
    person = people[enrollment.person_id]
    prog = progress[enrollment.person_id]
    status = prog&.status || "in_progress"
    cov = coverage.fetch(enrollment.person_id, { self: 0, manager: 0, last_at: nil })
    expected_count = expected.fetch(enrollment.role_id, 0)
    last_activity = [
      enrollment.enrolled_at, prog&.started_at, prog&.alignment_started_at,
      prog&.aligned_at, cov[:last_at]
    ].compact.max

    Participant.new(
      person_id: enrollment.person_id,
      name: person&.name || "Unknown",
      manager_id: person&.manager_id,
      role_id: enrollment.role_id,
      role_name: roles[enrollment.role_id]&.name,
      level_ordinal: enrollment.level_ordinal,
      status: status,
      expected_count: expected_count,
      self_count: cov[:self],
      manager_count: cov[:manager],
      self_done: expected_count.positive? && cov[:self] >= expected_count,
      manager_done: expected_count.positive? && cov[:manager] >= expected_count,
      aligned: status == "aligned",
      at_risk: at_risk?(status, last_activity),
      last_activity_at: last_activity
    )
  end

  # Distinct active capabilities bound to each role — the completion
  # denominator. Keyed by stable_id to match the rating key space.
  # @return [Hash{String => Integer}]
  def expected_capability_counts(role_ids)
    return {} if role_ids.empty?

    FrameworkState::CapabilityRoleBinding
      .joins(:capability)
      .where(role_id: role_ids, framework_capabilities: { status: "active" })
      .group("framework_capability_role_bindings.role_id")
      .count("DISTINCT framework_capabilities.stable_id")
  end

  # Per-person coverage at their assessed level + last rating activity.
  # @return [Hash{String => {self: Integer, manager: Integer, last_at: Time, nil}}]
  def coverage_by_person(person_ids)
    assessed_ordinal = AssessmentCycleEnrollment.active
      .where(cycle_id: @cycle.cycle_id, person_id: person_ids)
      .pluck(:person_id, :level_ordinal).to_h

    rows = AssessmentLevelRating
      .where(cycle_id: @cycle.cycle_id, person_id: person_ids)
      .pluck(:person_id, :capability_stable_id, :level_ordinal,
             :self_rated_frequency, :manager_rated_frequency,
             :last_self_rated_at, :last_manager_rated_at)

    acc = Hash.new { |hash, key| hash[key] = { self: Set.new, manager: Set.new, last_at: nil } }
    rows.each do |person_id, stable_id, ordinal, self_freq, manager_freq, self_at, manager_at|
      bucket = acc[person_id]
      [ self_at, manager_at ].compact.each do |timestamp|
        bucket[:last_at] = [ bucket[:last_at], timestamp ].compact.max
      end
      next unless ordinal == assessed_ordinal[person_id]

      bucket[:self] << stable_id if self_freq.present?
      bucket[:manager] << stable_id if manager_freq.present?
    end

    acc.transform_values { |b| { self: b[:self].size, manager: b[:manager].size, last_at: b[:last_at] } }
  end

  def at_risk?(status, last_activity)
    # A closed cycle has nothing actionable left — ratings are frozen, so
    # "at risk" (a chase-list signal) would be a permanent false alarm:
    # planned_end_at is always in the past and idleness only grows.
    return false if @cycle.closed?
    return false if status == "aligned"
    return true if @cycle.planned_end_at && @cycle.planned_end_at.to_time < @now
    return true if last_activity && last_activity < @now - AT_RISK_IDLE_DAYS.days

    false
  end

  def build_funnel(participants)
    Funnel.new(
      enrolled: participants.size,
      self_done: participants.count(&:self_done),
      manager_done: participants.count(&:manager_done),
      aligned: participants.count(&:aligned)
    )
  end

  def full_groups(participants, manager_groups)
    {
      manager: manager_groups,
      role: grouped(participants, :role_id) { |p| p.role_name || "Unassigned role" },
      level: grouped(participants, :level_ordinal) { |p| p.level_ordinal ? "Level #{p.level_ordinal}" : "No level" }
    }
  end

  def build_manager_groups(participants)
    manager_ids = participants.filter_map(&:manager_id).uniq
    names = manager_ids.empty? ? {} : Person.where(id: manager_ids).pluck(:id, :name).to_h
    grouped(participants, :manager_id) do |p|
      p.manager_id ? (names[p.manager_id] || "Unknown manager") : "No manager"
    end
  end

  def grouped(participants, attribute)
    participants.group_by(&attribute).map do |key, members|
      Group.new(
        key: key,
        label: yield(members.first),
        total: members.size,
        funnel: build_funnel(members),
        at_risk_count: members.count(&:at_risk)
      )
    end.sort_by { |group| -group.total }
  end

  # The manager subtree lagging most on alignment (tie-break: most at-risk).
  # Nil when there are no participants.
  def top_lagging(manager_groups)
    return nil if manager_groups.empty?

    manager_groups.min_by { |group| [ group.funnel.aligned_pct, -group.at_risk_count ] }
  end
end
