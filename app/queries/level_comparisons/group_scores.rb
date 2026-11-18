# frozen_string_literal: true

# Every role and level's middle scores, from each person's latest settled
# assessment: the most recent alignment their manager completed for their
# home role. A reopened alignment falls back to the one before it. People
# who have left, or been forgotten, are not counted.
#
# Each person is scored as their hero would score the agreed ratings, at the
# role and level the alignment assessed, so a group's 100% means what a
# person's 100% means.
class LevelComparisons::GroupScores
  # @param tenant [Tenant]
  def initialize(tenant:)
    @tenant = tenant
  end

  # @return [Array<Hash>] one per role and level: framework_id, role_id,
  #   level_ordinal, group_size, capability_medians (stable_id => score) and
  #   category_medians (category_id => score)
  def call
    ActsAsTenant.with_tenant(@tenant) do
      settled.group_by(&:framework_id).flat_map { |framework_id, rows| groups_in(framework_id, rows) }
    end
  end

  private

  def settled
    AssessmentCycleRoleAlignment
      .where(home: true, status: "aligned")
      .where(person_id: Person.active.remembered.select(:id))
      .group_by { |row| [ row.person_id, row.framework_id ] }
      .map { |_, rows| rows.max_by(&:aligned_at) }
  end

  def groups_in(framework_id, rows)
    framework = FrameworkState::Framework.find_by(framework_id:)
    return [] unless framework

    scopes = Assessments::RoleScope.for_roles(role_ids: rows.map(&:role_id).uniq, framework_id:)
    context = FrameworkContext.new(framework:, scopes:)
    ratings = ratings_for(rows, scopes)

    rows.group_by { |row| [ row.role_id, row.level_ordinal ] }.filter_map do |(role_id, level), members|
      next if scopes.fetch(role_id).empty?

      scorings = members.map { |row| context.scoring(row, ratings.fetch([ row.cycle_id, row.person_id ], [])) }
      { framework_id:, role_id:, level_ordinal: level, group_size: members.size,
        capability_medians: medians(scorings) { |scoring| capability_scores(scoring, scopes.fetch(role_id)) },
        category_medians: medians(scorings) { |scoring| category_scores(scoring, context.category_ids(role_id)) } }
    end
  end

  # Keyed by cycle and person, so each person is scored on their settled cycle alone.
  def ratings_for(rows, scopes)
    AssessmentLevelRating
      .where(cycle_id: rows.map(&:cycle_id).uniq)
      .within(rows.to_h { |row| [ row.person_id, scopes.fetch(row.role_id) ] })
      .group_by { |rating| [ rating.cycle_id, rating.person_id ] }
  end

  def capability_scores(scoring, scope)
    scope.bindings.filter_map do |binding|
      components = scoring.capability_components(binding)
      [ binding.capability.stable_id, components[:score] ] if components[:scorable]
    end
  end

  def category_scores(scoring, category_ids)
    category_ids.filter_map do |category_id|
      components = scoring.category_components(category_id)
      [ category_id, components[:score] ] if components[:scorable]
    end
  end

  def medians(scorings)
    scorings.flat_map { |scoring| yield(scoring) }.group_by(&:first)
      .transform_values { |pairs| median(pairs.map(&:last)) }
  end

  def median(scores)
    sorted = scores.sort
    middle = sorted.size / 2
    value = sorted.size.odd? ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2.0
    value.round(4)
  end

  # What scoring a person needs from their framework, loaded once.
  class FrameworkContext
    # @param framework [FrameworkState::Framework]
    # @param scopes [Hash{String => Assessments::RoleScope}]
    def initialize(framework:, scopes:)
      @framework = framework
      @scopes = scopes
    end

    # @param row [AssessmentCycleRoleAlignment] the settled assessment
    # @param ratings [Array<AssessmentLevelRating>] its ratings
    # @return [PersonDevelopment::Scoring] scored on the agreed ratings, as the hero scores them
    def scoring(row, ratings)
      PersonDevelopment::Scoring.new(
        level_ratings: ratings, bindings: @scopes.fetch(row.role_id).bindings, categories:,
        person_level: row.level_ordinal, all_level_ordinals: ordinals.fetch(row.role_id, [ row.level_ordinal ]),
        expectation_cells:, thresholds: @framework.scoring_thresholds || {}, perspective: :aligned_only
      )
    end

    # @param role_id [String]
    # @return [Array<String>] the categories the role's capabilities sit in
    def category_ids(role_id) = @scopes.fetch(role_id).bindings.map { |b| b.capability.category_id }.uniq

    private

    def categories
      @categories ||= FrameworkState::CapabilityCategory.where(category_id: @scopes.values.flat_map do |scope|
        scope.bindings.map { |b| b.capability.category_id }
      end.uniq).to_a
    end

    def ordinals
      @ordinals ||= FrameworkState::Level.where(role_id: @scopes.keys).pluck(:role_id, :ordinal)
        .group_by(&:first).transform_values { |pairs| pairs.map(&:last).sort }
    end

    def expectation_cells = @expectation_cells ||= @scopes.values.map(&:cells).reduce(Set.new, :|)
  end
  private_constant :FrameworkContext
end
