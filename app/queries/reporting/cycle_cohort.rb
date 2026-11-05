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
# Exposes per-person lifecycle status and timestamps, never rating *values*:
# the manager chain and tenant admins may see everything about a person, but
# this is a progress report and scores have their own surfaces.
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
  # and lifecycle status: `lifecycle` is an {Assessments::Lifecycle}, and
  # `role_alignments` their AssessmentCycleRoleAlignment rows (home first),
  # empty unless the caller asks.
  Participant = Data.define(
    :person_id, :name, :manager_id, :role_id, :role_name, :level_ordinal,
    :status, :expected_count, :self_count, :manager_count,
    :self_done, :manager_done, :aligned, :at_risk, :last_activity_at,
    :lifecycle, :role_alignments
  )

  # A grouping bucket (by manager / role / level) with its own funnel.
  Group = Data.define(:key, :label, :total, :funnel, :at_risk_count)

  Result = Data.define(
    :cycle, :total, :funnel, :status_counts, :at_risk_count,
    :participants, :groups, :top_lagging_group, :median_days_to_align
  ) do
    def any? = total.positive?
  end

  # @param cycle [AssessmentCycle]
  # @param scope_person_ids [Array<String>, nil] restrict to these people
  #   (a manager's subtree); nil = the whole cycle
  # @param mode [Symbol] :summary (card) or :full (drill-down view)
  # @param now [Time] injectable clock for at-risk calculations
  # @param include_role_alignments [Boolean] load every role alignment per
  #   participant (the MCP payload); the web views don't show them
  def initialize(cycle:, scope_person_ids: nil, mode: :full, now: Time.current, include_role_alignments: false)
    @cycle = cycle
    @scope_person_ids = scope_person_ids
    @mode = mode
    @now = now
    @include_role_alignments = include_role_alignments
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
      top_lagging_group: top_lagging(manager_groups),
      median_days_to_align: median_days_to_align(participants)
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
    scope_by_person = role_scopes_by_person(enrollments)
    coverage = coverage_by_person(enrollments, scope_by_person)
    alignments = @include_role_alignments ? role_alignments_by_person(person_ids) : {}

    enrollments.map do |enrollment|
      build_participant(enrollment, progress, people, roles, scope_by_person, coverage, alignments)
    end
  end

  def build_participant(enrollment, progress, people, roles, scope_by_person, coverage, alignments)
    person = people[enrollment.person_id]
    prog = progress[enrollment.person_id]
    status = prog&.status || "in_progress"
    cov = coverage.fetch(enrollment.person_id, { self: 0, manager: 0, last_at: nil })
    # The completion denominator: the assessed role's cells at the assessed
    # level — the same set Assessments::LevelCoverage counts against.
    expected_count = scope_by_person.fetch(enrollment.person_id)
      .at_level(enrollment.level_ordinal).capability_stable_ids.size
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
      last_activity_at: last_activity,
      lifecycle: Assessments::Lifecycle.from(enrollment: enrollment, progress: prog),
      role_alignments: alignments.fetch(enrollment.person_id, [])
    )
  end

  # Home role first, then lens roles in the order their conversations began.
  # @return [Hash{String => Array<AssessmentCycleRoleAlignment>}]
  def role_alignments_by_person(person_ids)
    AssessmentCycleRoleAlignment.where(cycle_id: @cycle.cycle_id, person_id: person_ids)
      .order(home: :desc, alignment_started_at: :asc).group_by(&:person_id)
  end

  # Enrolment to (latest) alignment, over the participants aligned so far.
  # @return [Float, nil] days, to one decimal place
  def median_days_to_align(participants)
    days = participants.select(&:aligned).filter_map { |p| p.lifecycle.days_to_align }.sort
    return nil if days.empty?

    mid = days.size / 2
    median = days.size.odd? ? days[mid] : (days[mid - 1] + days[mid]) / 2
    median.round(1)
  end

  # person_id => the cells their assessed role (enrollment snapshot) reads.
  # @return [Hash{String => Assessments::RoleScope}]
  def role_scopes_by_person(enrollments)
    scopes = Assessments::RoleScope.for_roles(role_ids: enrollments.map(&:role_id), framework_id: @cycle.framework_id)
    empty = Assessments::RoleScope.empty(framework_id: @cycle.framework_id)
    enrollments.to_h { |e| [ e.person_id, scopes[e.role_id] || empty ] }
  end

  # Per-person coverage at their assessed level, in their assessed role's
  # cells, + last rating activity.
  # @return [Hash{String => {self: Integer, manager: Integer, last_at: Time, nil}}]
  def coverage_by_person(enrollments, scope_by_person)
    assessed_ordinal = enrollments.to_h { |e| [ e.person_id, e.level_ordinal ] }

    rows = AssessmentLevelRating
      .where(cycle_id: @cycle.cycle_id)
      .within(scope_by_person)
      .pluck(:person_id, :capability_stable_id, :level_ordinal,
             :self_rated_frequency, :manager_rated_frequency,
             :self_rating_source, :manager_rating_source)

    acc = Hash.new { |hash, key| hash[key] = { self: Set.new, manager: Set.new } }
    rows.each do |person_id, stable_id, ordinal, self_freq, manager_freq, self_src, manager_src|
      next unless ordinal == assessed_ordinal[person_id]

      # Funnel counts VETTED sides only — a carried (seeded) value isn't
      # done, it's To confirm. Matches Assessments::LevelCoverage and the
      # /assessments chips, so the cohort report and the individual list
      # never disagree on what "done" means.
      bucket = acc[person_id]
      bucket[:self] << stable_id if self_freq.present? && self_src != "seeded"
      bucket[:manager] << stable_id if manager_freq.present? && manager_src != "seeded"
    end

    last_at = last_rating_activity(scope_by_person.keys)
    scope_by_person.keys.index_with do |person_id|
      bucket = acc.fetch(person_id, { self: Set.new, manager: Set.new })
      { self: bucket[:self].size, manager: bucket[:manager].size, last_at: last_at[person_id] }
    end
  end

  # The latest rating each person touched, in any role: rating a cell the
  # assessed role doesn't bind is still activity, so it keeps a person off
  # the idle list. Deliberately counts seeded timestamps too — they coincide
  # with enrollment, which already counts as activity for at-risk.
  # @return [Hash{String => Time}]
  def last_rating_activity(person_ids)
    AssessmentLevelRating.across_all_roles
      .where(cycle_id: @cycle.cycle_id, person_id: person_ids)
      .group(:person_id)
      .pluck(:person_id, Arel.sql("GREATEST(MAX(last_self_rated_at), MAX(last_manager_rated_at))"))
      .to_h
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
