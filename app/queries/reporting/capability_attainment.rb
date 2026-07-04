# frozen_string_literal: true

# Aggregate capability attainment for an assessment cycle: for each role (and
# role family), the share of enrolled people whose agreed level on each bound
# capability is at or above their assessed level — plus a category roll-up
# (% of people passing the existing category gate from
# {PersonDevelopment::Scoring#category_results}).
#
# Read-only and compute-on-read (the {Reporting::CycleCohort} pattern): no new
# tables, no projection. One bulk ratings query per call, then one
# {PersonDevelopment::Scoring} per participant at their enrollment-snapshot
# role/level (ADR-19). Keyed on `capability_stable_id`, so results survive
# framework version migrations.
#
# == Buckets (per person × capability bound to their role)
#
#   above — agreed_level(capability) >  assessed level
#   at    — agreed_level(capability) == assessed level
#   below — otherwise. This includes "not yet assessed": an unrated own-level
#           cell scores 0.0 under every perspective, so each cell also carries
#           `n_assessed` — the UI must show coverage alongside attainment.
#
# == Privacy — small-cohort suppression
#
# This is the first surface exposing rating-derived values in aggregate to
# viewers who cannot open the underlying individual assessments (managers see
# their subtree, including skip-levels). With `suppress_small_groups: true`,
# any cell whose denominator is under {MIN_COHORT} keeps its coverage counts
# but nils the buckets/percentages. Family cells apply a secondary guard: when
# the people hidden behind suppressed role cells number 1..MIN_COHORT-1, the
# family cell is suppressed too — otherwise subtracting the visible role cells
# from the family cell would reconstruct the small cohort. Full-access viewers
# (admin/HR) pass `false` — they can already open individual assessments.
class Reporting::CapabilityAttainment
  MIN_COHORT = 4

  # One (group × capability) cell. Buckets are nil when suppressed; the
  # coverage counts (`n_assessed` / `n_in_group`) always survive.
  Cell = Data.define(:below, :at, :above, :n_assessed, :n_in_group, :suppressed) do
    def at_or_above = suppressed ? nil : at + above
    def at_or_above_pct = suppressed || n_in_group.zero? ? nil : (at_or_above.to_f / n_in_group * 100).round
    def assessed_pct = n_in_group.zero? ? 0 : (n_assessed.to_f / n_in_group * 100).round
  end

  # One (group × category) cell — % of members passing the category gate.
  CategoryCell = Data.define(:pass_count, :n_in_group, :suppressed) do
    def pass_pct = suppressed || n_in_group.zero? ? nil : (pass_count.to_f / n_in_group * 100).round
  end

  # A role or role-family column: cells keyed by capability stable_id,
  # category_cells keyed by category_id. `family_key` groups role columns
  # under their family header (nil on family groups themselves).
  Group = Data.define(:key, :label, :family_key, :n_people, :cells, :category_cells)

  CapabilityRow = Data.define(:stable_id, :name, :category_id)
  CategoryRow = Data.define(:category_id, :name)

  Result = Data.define(
    :cycle, :perspective, :total_people,
    :categories, :capabilities, :roles, :families, :suppression_floor
  ) do
    def any? = total_people.positive?
  end

  # Internal: one participant's derived outcomes.
  PersonOutcome = Data.define(:person_id, :role_id, :family_key, :buckets, :assessed, :category_pass)
  private_constant :PersonOutcome

  # @param cycle [AssessmentCycle]
  # @param scope_person_ids [Array<String>, nil] restrict to these people
  #   (a manager's subtree); nil = the whole cycle
  # @param perspective [Symbol] which rating perspective to score
  #   (see PersonDevelopment::Scoring::PERSPECTIVES)
  # @param suppress_small_groups [Boolean] apply the MIN_COHORT floor —
  #   true for subtree-scoped viewers, false for full-access admins/HR
  def initialize(cycle:, scope_person_ids: nil, perspective: :effective, suppress_small_groups: false)
    unless PersonDevelopment::Scoring::PERSPECTIVES.include?(perspective)
      raise ArgumentError, "unknown perspective: #{perspective.inspect}"
    end

    @cycle = cycle
    @scope_person_ids = scope_person_ids
    @perspective = perspective
    @suppress = suppress_small_groups
  end

  # @return [Reporting::CapabilityAttainment::Result]
  def call
    enrollments = load_enrollments
    return empty_result if enrollments.empty?

    load_structure(enrollments)
    outcomes = enrollments.map { |enrollment| build_outcome(enrollment) }

    role_groups = build_role_groups(outcomes)
    family_groups = build_family_groups(outcomes, role_groups)

    Result.new(
      cycle: @cycle,
      perspective: @perspective,
      total_people: outcomes.size,
      categories: category_rows,
      capabilities: capability_rows,
      roles: role_groups,
      families: family_groups,
      suppression_floor: @suppress ? MIN_COHORT : nil
    )
  end

  private

  # Enrollments without a snapshot role/level cannot be scored against a
  # capability bar — they are excluded from the aggregation entirely.
  def load_enrollments
    scope = AssessmentCycleEnrollment.active
      .where(cycle_id: @cycle.cycle_id)
      .where.not(role_id: nil).where.not(level_ordinal: nil)
    scope = scope.where(person_id: @scope_person_ids) if @scope_person_ids
    scope.to_a
  end

  def load_structure(enrollments)
    role_ids = enrollments.map(&:role_id).uniq

    @roles = FrameworkState::Role.where(role_id: role_ids).index_by(&:role_id)
    @bindings_by_role = FrameworkState::CapabilityRoleBinding
      .joins(:capability)
      .where(role_id: role_ids, framework_capabilities: { status: "active" })
      .includes(:capability)
      .group_by(&:role_id)
    @ordinals_by_role = FrameworkState::Level.where(role_id: role_ids)
      .pluck(:role_id, :ordinal)
      .group_by(&:first).transform_values { |pairs| pairs.map(&:last).sort }

    category_ids = @bindings_by_role.values.flatten.map { |b| b.capability.category_id }.uniq
    @categories = FrameworkState::CapabilityCategory.where(category_id: category_ids).to_a

    @ratings_by_person = AssessmentLevelRating
      .where(cycle_id: @cycle.cycle_id, person_id: enrollments.map(&:person_id))
      .group_by(&:person_id)
  end

  def build_outcome(enrollment)
    bindings = @bindings_by_role.fetch(enrollment.role_id, [])
    ratings = @ratings_by_person.fetch(enrollment.person_id, [])
    level = enrollment.level_ordinal

    scoring = PersonDevelopment::Scoring.new(
      level_ratings: ratings,
      bindings: bindings,
      categories: @categories,
      person_level: level,
      all_level_ordinals: @ordinals_by_role.fetch(enrollment.role_id, [ level ]),
      thresholds: framework_thresholds,
      perspective: @perspective
    )

    assessed_ids = assessed_stable_ids(ratings, level)
    buckets = bindings.to_h do |binding|
      stable_id = binding.capability.stable_id
      [ stable_id, bucket_for(scoring.agreed_level_for(stable_id), level) ]
    end

    PersonOutcome.new(
      person_id: enrollment.person_id,
      role_id: enrollment.role_id,
      family_key: @roles[enrollment.role_id]&.role_family_id,
      buckets: buckets,
      assessed: assessed_ids,
      category_pass: scoring.category_results.transform_values { |r| r[:pass] }
    )
  end

  def bucket_for(agreed_level, assessed_level)
    return :below if agreed_level.nil? || agreed_level < assessed_level

    agreed_level == assessed_level ? :at : :above
  end

  # Capabilities with an explicit own-level rating under the active
  # perspective — the coverage numerator.
  def assessed_stable_ids(ratings, level)
    ratings.each_with_object(Set.new) do |rating, set|
      next unless rating.level_ordinal == level

      set << rating.capability_stable_id if rated_under_perspective?(rating)
    end
  end

  def rated_under_perspective?(rating)
    case @perspective
    when :self_only    then rating.self_rated_frequency.present?
    when :manager_only then rating.manager_rated_frequency.present?
    when :aligned_only then rating.aligned_frequency.present?
    else
      rating.aligned_frequency.present? ||
        rating.manager_rated_frequency.present? ||
        rating.self_rated_frequency.present?
    end
  end

  def build_role_groups(outcomes)
    outcomes.group_by(&:role_id).map do |role_id, members|
      role = @roles[role_id]
      Group.new(
        key: role_id,
        label: role&.name || "Unknown role",
        family_key: role&.role_family_id,
        n_people: members.size,
        cells: build_cells(members),
        category_cells: build_category_cells(members)
      )
    end.sort_by { |group| [ family_label(group.family_key), group.label ] }
  end

  def build_family_groups(outcomes, role_groups)
    outcomes.group_by(&:family_key).map do |family_key, members|
      roles_in_family = role_groups.select { |group| group.family_key == family_key }
      Group.new(
        key: family_key,
        label: family_label(family_key),
        family_key: nil,
        n_people: members.size,
        cells: guard_differencing(build_cells(members), roles_in_family.map(&:cells)),
        category_cells: guard_differencing(build_category_cells(members), roles_in_family.map(&:category_cells))
      )
    end.sort_by(&:label)
  end

  def build_cells(members)
    tallies = Hash.new { |hash, key| hash[key] = { below: 0, at: 0, above: 0, assessed: 0, n: 0 } }
    members.each do |member|
      member.buckets.each do |stable_id, bucket|
        tally = tallies[stable_id]
        tally[:n] += 1
        tally[bucket] += 1
        tally[:assessed] += 1 if member.assessed.include?(stable_id)
      end
    end

    tallies.transform_values do |tally|
      suppress_cell(Cell.new(
        below: tally[:below], at: tally[:at], above: tally[:above],
        n_assessed: tally[:assessed], n_in_group: tally[:n], suppressed: false
      ))
    end
  end

  def build_category_cells(members)
    tallies = Hash.new { |hash, key| hash[key] = { pass: 0, n: 0 } }
    members.each do |member|
      member.category_pass.each do |category_id, pass|
        tally = tallies[category_id]
        tally[:n] += 1
        tally[:pass] += 1 if pass
      end
    end

    tallies.transform_values do |tally|
      suppress_cell(CategoryCell.new(pass_count: tally[:pass], n_in_group: tally[:n], suppressed: false))
    end
  end

  def suppress_cell(cell)
    return cell unless @suppress && cell.n_in_group < MIN_COHORT

    blank_cell(cell)
  end

  def blank_cell(cell)
    case cell
    when Cell
      cell.with(below: nil, at: nil, above: nil, suppressed: true)
    when CategoryCell
      cell.with(pass_count: nil, suppressed: true)
    end
  end

  # Secondary suppression: a family cell whose visible role cells account for
  # all but 1..MIN_COHORT-1 of its members would let a viewer reconstruct the
  # suppressed remainder by subtraction — suppress the family cell too.
  def guard_differencing(family_cells, role_cell_maps)
    return family_cells unless @suppress

    family_cells.to_h do |key, cell|
      visible = role_cell_maps.sum do |cells|
        role_cell = cells[key]
        role_cell && !role_cell.suppressed ? role_cell.n_in_group : 0
      end
      hidden = cell.n_in_group - visible
      [ key, hidden.between?(1, MIN_COHORT - 1) ? blank_cell(cell) : cell ]
    end
  end

  def family_label(family_key)
    @family_labels ||= FrameworkState::RoleFamily
      .where(role_family_id: @roles.values.map(&:role_family_id).compact.uniq)
      .pluck(:role_family_id, :name).to_h
    @family_labels[family_key] || "Ungrouped roles"
  end

  # Constant across the whole call — memoized so per-participant scoring
  # doesn't rebuild it.
  def framework_thresholds
    @framework_thresholds ||= begin
      framework = @cycle.framework
      if framework
        {
          mastery_threshold: framework.mastery_threshold&.to_f,
          meeting_expectation_threshold: framework.meeting_expectation_threshold&.to_f,
          underperforming_threshold: framework.underperforming_threshold&.to_f,
          overperformance_cap: framework.overperformance_cap,
          deficit_threshold: framework.deficit_threshold&.to_f
        }
      else
        {}
      end
    end
  end

  # Bound capabilities across all scoped roles, ordered by category then name —
  # the heatmap's row skeleton.
  def capability_rows
    @bindings_by_role.values.flatten.map(&:capability).uniq(&:stable_id)
      .map { |cap| CapabilityRow.new(stable_id: cap.stable_id, name: cap.name, category_id: cap.category_id) }
      .sort_by { |row| [ category_name(row.category_id), row.name ] }
  end

  def category_rows
    @categories
      .map { |category| CategoryRow.new(category_id: category.category_id, name: category.name) }
      .sort_by(&:name)
  end

  def category_name(category_id)
    @category_names ||= @categories.to_h { |category| [ category.category_id, category.name ] }
    @category_names[category_id] || ""
  end

  def empty_result
    Result.new(
      cycle: @cycle, perspective: @perspective, total_people: 0,
      categories: [], capabilities: [], roles: [], families: [],
      suppression_floor: @suppress ? MIN_COHORT : nil
    )
  end
end
