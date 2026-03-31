# frozen_string_literal: true

# Transforms framework read models and assessment ratings into a structured
# hash for the self-assessment capability matrix.
#
# Single-role variant of {Frameworks::MatrixDataBuilder}. Enriches each cell
# with the person's current self-rated frequency, binding weight/tolerance,
# and scoring output.
#
# Operates on in-memory associations — no additional queries beyond the
# initial ratings load.
#
# @example
#   data = Assessments::MatrixDataBuilder.new(
#     framework: framework, role: role, level: level,
#     person_id: person.id, categories: eager_loaded_categories
#   ).build
#
class Assessments::MatrixDataBuilder
  # @param framework [FrameworkState::Framework]
  # @param role [FrameworkState::Role] the person's assigned role
  # @param level [FrameworkState::Level] the person's assigned level
  # @param person_id [String] UUID
  # @param categories [Array<FrameworkState::CapabilityCategory>] eager-loaded
  def initialize(framework:, role:, level:, person_id:, categories:)
    @framework = framework
    @role = role
    @level = level
    @person_id = person_id
    @categories = categories
  end

  # Builds the assessment matrix data structure.
  #
  # @return [Hash]
  def build
    @ratings_index = load_ratings
    @bindings_by_cap = index_bindings
    levels = build_levels
    ordinals = levels.map { |l| l[:ordinal] }
    categories = build_categories(ordinals)
    scoring_engine = build_scoring_engine(categories)
    enrich_levels_with_performance_ratios(levels, scoring_engine)
    enrich_capabilities_with_contributions(categories, scoring_engine)
    scoring = extract_scoring(scoring_engine)

    {
      role: @role,
      level: @level,
      person_level: @level.ordinal,
      merged_levels: levels,
      categories: categories,
      scoring: scoring,
      self_scoring: build_perspective_scoring(categories, :self_only),
      manager_scoring: build_perspective_scoring(categories, :manager_only),
      aligned_scoring: build_perspective_scoring(categories, :aligned_only),
      meeting_expectation_threshold: @framework.meeting_expectation_threshold&.to_f ||
        PersonDevelopment::Scoring::DEFAULT_MEETING_EXPECTATION_THRESHOLD,
      mastery_threshold: @framework.mastery_threshold&.to_f ||
        PersonDevelopment::Scoring::DEFAULT_MASTERY_THRESHOLD,
      inferred_level: scoring_engine.inferred_level,
      total_cells: count_total_cells(categories),
      rated_cells: count_rated_cells(categories)
    }
  end

  private

  # Builds the level columns for the person's assigned role.
  #
  # @return [Array<Hash>]
  def build_levels
    @role.levels.sort_by(&:ordinal).map do |lvl|
      { ordinal: lvl.ordinal, level_code: lvl.code, level_title: lvl.title, level_id: lvl.level_id }
    end
  end

  # Builds the category → capability → cell structure.
  #
  # @param ordinals [Array<Integer>]
  # @return [Array<Hash>]
  def build_categories(ordinals)
    @categories.filter_map do |category|
      capabilities = build_capabilities(category, ordinals)
      next if capabilities.empty?

      {
        category: category,
        deficit_threshold: category.deficit_threshold,
        capabilities: capabilities
      }
    end
  end

  # Builds capability data for a category, filtered to the person's role.
  #
  # @return [Array<Hash>]
  def build_capabilities(category, ordinals)
    category.capabilities.select { |c| c.status == "active" }.filter_map do |capability|
      binding = @bindings_by_cap[capability.capability_id]
      next unless binding  # skip capabilities not bound to this role

      cells = build_cells(capability, ordinals)

      {
        capability: capability,
        binding: binding,
        weight: binding.weight.to_f,
        cells: cells
      }
    end
  end

  # Builds cells for each level ordinal with expectation + current rating.
  #
  # @return [Hash<Integer, Hash>]
  def build_cells(capability, ordinals)
    expectations_by_ordinal = capability.expectations.index_by(&:level_ordinal)

    ordinals.each_with_object({}) do |ordinal, cells|
      expectation = expectations_by_ordinal[ordinal]
      next unless expectation

      rating = @ratings_index[[ capability.stable_id, ordinal ]]
      illustrations = expectation.illustrations
        .select { |ill| ill.role_id == @role.role_id }
        .sort_by(&:ordinal)

      cells[ordinal] = {
        expectation: expectation,
        current_frequency: rating&.self_rated_frequency,
        manager_frequency: rating&.manager_rated_frequency,
        aligned_frequency: rating&.aligned_frequency,
        illustrations: illustrations,
        illustration_count: illustrations.size
      }
    end
  end

  # Loads and indexes all AssessmentLevelRatings for this person + framework.
  #
  # @return [Hash{[String, Integer] => AssessmentLevelRating}]
  def load_ratings
    AssessmentLevelRating
      .for_person(@person_id)
      .for_framework(@framework.framework_id)
      .each_with_object({}) do |r, h|
        h[[ r.capability_stable_id, r.level_ordinal ]] = r
      end
  end

  # Indexes CapabilityRoleBindings for the person's role by capability_id.
  #
  # @return [Hash{String => FrameworkState::CapabilityRoleBinding}]
  def index_bindings
    @categories
      .flat_map(&:capabilities)
      .flat_map(&:bindings)
      .select { |b| b.role_id == @role.role_id }
      .index_by(&:capability_id)
  end

  # Adds :performance_ratio to each level hash for ordinals up to person_level + 1.
  # Mutates merged_levels in place. Levels beyond next level get nil.
  #
  # @param levels [Array<Hash>] from build_levels
  # @param scoring [PersonDevelopment::Scoring]
  def enrich_levels_with_performance_ratios(levels, scoring)
    next_ordinal = @level.ordinal + 1
    levels.each do |level|
      if level[:ordinal] <= next_ordinal
        level[:performance_ratio] = scoring.performance_ratio_at_level(level[:ordinal])
        level[:level_verdict] = scoring.level_verdict(level[:ordinal])
      end
    end
  end

  # Adds :contribution to each capability hash — the raw contribution score.
  #
  # @param categories_data [Array<Hash>]
  # @param scoring [PersonDevelopment::Scoring]
  def enrich_capabilities_with_contributions(categories_data, scoring)
    categories_data.each do |cat_data|
      cat_data[:capabilities].each do |cap_data|
        cap_data[:contribution] = scoring.raw_contribution(cap_data[:binding])
      end
    end
  end

  # Builds the PersonDevelopment::Scoring engine instance.
  #
  # @param categories_data [Array<Hash>] the built categories structure
  # @param perspective [Symbol] frequency perspective for scoring
  # @return [PersonDevelopment::Scoring]
  def build_scoring_engine(categories_data, perspective: :effective)
    bindings = categories_data.flat_map { |c| c[:capabilities].map { |cap| cap[:binding] } }.compact
    category_records = categories_data.map { |c| c[:category] }
    all_ordinals = build_levels.map { |l| l[:ordinal] }

    PersonDevelopment::Scoring.new(
      level_ratings: @ratings_index.values,
      bindings: bindings,
      categories: category_records,
      person_level: @level.ordinal,
      all_level_ordinals: all_ordinals,
      perspective: perspective,
      thresholds: {
        mastery_threshold: @framework.mastery_threshold&.to_f,
        meeting_expectation_threshold: @framework.meeting_expectation_threshold&.to_f,
        overperformance_cap: @framework.overperformance_cap,
        deficit_threshold: @framework.deficit_threshold&.to_f
      }
    )
  end

  # Extracts scoring results from the engine.
  #
  # @param scoring [PersonDevelopment::Scoring]
  # @return [Hash]
  def extract_scoring(scoring)
    {
      performance_ratio: scoring.performance_ratio,
      meeting_expectations: scoring.meeting_expectations?,
      mastering: scoring.mastering?,
      category_results: scoring.category_results,
      promotion_readiness: scoring.promotion_readiness,
      capability_statuses: scoring.capability_statuses,
      block_reasons: scoring.block_reasons
    }
  end

  # Builds scoring output for a single perspective. Returns nil when no
  # ratings exist for that perspective (e.g. no manager has rated yet).
  #
  # @param categories_data [Array<Hash>]
  # @param perspective [Symbol] :self_only, :manager_only, or :aligned_only
  # @return [Hash, nil]
  def build_perspective_scoring(categories_data, perspective)
    return nil unless has_ratings_for_perspective?(perspective)

    engine = build_scoring_engine(categories_data, perspective: perspective)
    extract_scoring(engine)
  end

  # Whether any rating records have a value for the given perspective.
  #
  # @param perspective [Symbol]
  # @return [Boolean]
  def has_ratings_for_perspective?(perspective)
    field =
      case perspective
      when :self_only    then :self_rated_frequency
      when :manager_only then :manager_rated_frequency
      when :aligned_only then :aligned_frequency
      else return true
      end

    @ratings_index.values.any? { |r| r.public_send(field).present? }
  end

  def count_total_cells(categories)
    categories.sum { |c| c[:capabilities].sum { |cap| cap[:cells].size } }
  end

  def count_rated_cells(categories)
    categories.sum do |c|
      c[:capabilities].sum do |cap|
        cap[:cells].count { |_, cell| cell[:current_frequency].present? }
      end
    end
  end
end
