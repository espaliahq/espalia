# frozen_string_literal: true

# A team's capabilities as one picture: each capability's score is the mean
# of everyone's score on it, each person scored against their own level on
# their open cycle, so 1.0 means the team meets it on average. One role at a
# time, since capabilities differ between roles.
#
# Only people whose own score has unlocked count, and a capability someone
# hasn't rated is left out of that capability's mean rather than read as 0.
# Names never leave this query: it returns counts and means only.
class Assessments::TeamCapabilities
  # A role the team holds, with how many of them hold it.
  Role = Data.define(:role_id, :name, :people)

  # A level on the role's ladder, with how many on the role are at it.
  Level = Data.define(:ordinal, :code, :people)

  # One capability: the team's mean `score` (nil when nobody is scored on
  # it), how many were `scored` and how many of them are `short` of their level.
  Capability = Data.define(:stable_id, :name, :category_id, :category_name, :hue, :score, :scored, :short) do
    # @return [Boolean] whether the team meets it on average
    def met? = !score.nil? && score >= 1.0

    # @return [Boolean] whether more than half of those scored are short
    def gap? = short * 2 > scored
  end

  # `people` are those in view on the role and level; `scored` those of them
  # with a score, and `scored_on_role` those with one at any level of the role.
  Result = Data.define(:people, :scored, :scored_on_role, :capabilities, :roles, :role, :levels, :level_ordinal) do
    # @return [Integer] capabilities the team meets on average
    def met = capabilities.count(&:met?)

    # @return [Array<Capability>] where more than half the team is short
    def gaps = capabilities.select(&:gap?)
  end

  # Someone on the team, at the role and level their open cycle assesses.
  Member = Data.define(:person_id, :cycle_id, :framework_id, :role_id, :level_ordinal)
  private_constant :Member

  RATED = { self_only: :self_rated_frequency, manager_only: :manager_rated_frequency,
            aligned_only: :aligned_frequency }.freeze

  # @param person_ids [Array<String>] the team
  # @param perspective [Symbol] :manager_only, :self_only or :aligned_only
  # @param role_id [String, nil] the role to show; nil for the one most of the team holds
  # @param level_ordinal [Integer, nil] one level to narrow to; nil for every level, as it is when `role_id` isn't in the team
  def initialize(person_ids:, perspective: :manager_only, role_id: nil, level_ordinal: nil)
    @person_ids = person_ids
    @perspective = perspective
    @rated = RATED.fetch(perspective)
    @role_id = role_id
    @level_ordinal = level_ordinal
  end

  # @return [Result]
  def call
    fell_back = @role_id && role&.role_id != @role_id
    @level_ordinal = nil if role && (fell_back || ladder.none? { |level| level.ordinal == @level_ordinal })
    on_role = role ? enrollments.select { |enrollment| enrollment.role_id == role.role_id } : []
    in_view = @level_ordinal ? on_role.select { |enrollment| enrollment.level_ordinal == @level_ordinal } : on_role
    scored_on_role = on_role.filter_map { |enrollment| scoring_for(enrollment) }
    scorings = scored_on_role.select { |_, _, level| @level_ordinal.nil? || level == @level_ordinal }
    Result.new(people: in_view.size, scored: scorings.size, scored_on_role: scored_on_role.size,
               capabilities: role ? capabilities(scorings) : [], roles:, role:, levels: role ? levels(on_role) : [],
               level_ordinal: @level_ordinal)
  end

  private

  # Everyone on the team in an open cycle, one per person and role, at the
  # role and level their enrollment assesses (ADR-19), or their assignment's
  # for an enrollment taken before that snapshot.
  def enrollments
    @enrollments ||= begin
      rows = AssessmentCycleEnrollment.active.eager_load(:cycle)
        .where(person_id: @person_ids, assessment_cycles: { status: "open" }).to_a
      assigned = assignments_for(rows.reject { |row| row.role_id && row.level_ordinal })
      rows.filter_map do |row|
        role_id, level = row.role_id && row.level_ordinal ? [ row.role_id, row.level_ordinal ] :
          assigned[[ row.person_id, row.cycle.framework_id ]]
        next unless role_id && level

        Member.new(person_id: row.person_id, cycle_id: row.cycle_id, framework_id: row.cycle.framework_id,
                   role_id:, level_ordinal: level)
      end.uniq { |member| [ member.person_id, member.role_id ] }
    end
  end

  def assignments_for(rows)
    return {} if rows.empty?

    PersonFrameworkAssignment.where(person_id: rows.map(&:person_id)).includes(:level).to_a
      .to_h { |a| [ [ a.person_id, a.framework_id ], [ a.role_id, a.level&.ordinal ] ] }
  end

  def roles
    @roles ||= begin
      names = FrameworkState::Role.where(role_id: enrollments.map(&:role_id).uniq).pluck(:role_id, :name).to_h
      enrollments.group_by(&:role_id).map { |role_id, list| Role.new(role_id:, name: names[role_id], people: list.size) }
        .sort_by { |r| [ -r.people, r.name.to_s ] }
    end
  end

  def role = @role ||= roles.find { |r| r.role_id == @role_id } || roles.first

  def levels(on_role)
    counts = on_role.map(&:level_ordinal).tally
    ladder.map { |level| Level.new(ordinal: level.ordinal, code: level.code, people: counts.fetch(level.ordinal, 0)) }
  end

  def ladder = @ladder ||= FrameworkState::Level.where(role_id: role.role_id).order(:ordinal).to_a

  def framework_id = enrollments.find { |member| member.role_id == role.role_id }.framework_id

  def scope = @scope ||= Assessments::RoleScope.for(role_id: role.role_id, framework_id:)

  # The person's scoring, or nil until their score unlocks as their hero's does.
  def scoring_for(enrollment)
    mine = ratings.fetch([ enrollment.cycle_id, enrollment.person_id ], [])
    return unless unlocked?(mine, enrollment)

    PersonDevelopment::Scoring.new(
      level_ratings: mine, bindings: scope.bindings, categories:, person_level: enrollment.level_ordinal,
      all_level_ordinals: ladder.map(&:ordinal), expectation_cells: scope.cells,
      thresholds: framework&.scoring_thresholds || {}, perspective: @perspective
    ).then { |scoring| [ scoring, mine, enrollment.level_ordinal ] }
  end

  def unlocked?(mine, enrollment)
    level = enrollment.level_ordinal
    total = scope.at_level(level).cells.size
    rated = mine.count { |rating| rating.level_ordinal == level && rating[@rated].present? }
    total.positive? &&
      rated >= Views::Assessments::HeroSummary.unlock_target_for(total, awaiting_agreement: awaiting_agreement?(enrollment))
  end

  # As the person's own read: agreed ratings wait for every cell only while
  # an alignment at their level is under way.
  def awaiting_agreement?(enrollment)
    @perspective == :aligned_only &&
      aligning.include?([ enrollment.cycle_id, enrollment.person_id, enrollment.level_ordinal ])
  end

  def aligning
    @aligning ||= begin
      people = enrollments.select { |enrollment| enrollment.role_id == role.role_id }
      AssessmentCycleRoleAlignment.where(status: "aligning", role_id: role.role_id,
                                         cycle_id: people.map(&:cycle_id).uniq, person_id: people.map(&:person_id))
        .pluck(:cycle_id, :person_id, :level_ordinal).to_set
    end
  end

  def capabilities(scorings)
    hues = category_hues
    scope.bindings.map do |binding|
      stable_id = binding.capability.stable_id
      scores = scorings.filter_map { |scoring, mine, level| score_for(scoring, mine, level, binding) }
      Capability.new(stable_id:, name: binding.capability.name, category_id: binding.capability.category_id,
                     category_name: category_names[binding.capability.category_id],
                     hue: hues.fetch(binding.capability.category_id), score: scores.empty? ? nil : scores.sum / scores.size,
                     scored: scores.size, short: scores.count { |score| score < 1.0 })
    end
  end

  # Nil when the person has no expectation, or no rating, at their level.
  def score_for(scoring, mine, level, binding)
    stable_id = binding.capability.stable_id
    components = scoring.capability_components(binding)
    return unless components[:scorable]
    return unless mine.any? { |r| r.capability_stable_id == stable_id && r.level_ordinal == level && r[@rated].present? }

    components[:score]
  end

  # Categories take hues in the framework's order, as each card's blades do.
  def category_hues
    hues = Assessments::CapabilityShape::HUES
    scope.bindings.map { |b| b.capability.category_id }.uniq.each_with_index.to_h { |id, i| [ id, hues[i % hues.size] ] }
  end

  def categories
    @categories ||= FrameworkState::CapabilityCategory.where(category_id: scope.bindings.map { |b| b.capability.category_id }.uniq).to_a
  end

  def category_names = @category_names ||= categories.to_h { |c| [ c.category_id, c.name ] }

  def framework
    return @framework if defined?(@framework)

    @framework = FrameworkState::Framework.find_by(framework_id:)
  end

  def ratings
    @ratings ||= begin
      people = enrollments.select { |enrollment| enrollment.role_id == role.role_id }
      AssessmentLevelRating.where(cycle_id: people.map(&:cycle_id).uniq)
        .within(people.to_h { |enrollment| [ enrollment.person_id, scope ] })
        .group_by { |rating| [ rating.cycle_id, rating.person_id ] }
    end
  end
end
