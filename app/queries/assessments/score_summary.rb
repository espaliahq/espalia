# frozen_string_literal: true

# One assessment's scores on the level-independent scale (ADR-21), shaped
# for a client that has no screen — the MCP read tools.
#
# The web renders these numbers through `Assessments::MatrixDataBuilder`;
# this query runs the same builder and reshapes its scoring output, so the
# number an agent reads is the number the person sees. It never recomputes
# anything itself.
#
# Percentages are whole numbers, because that is the scale's own unit:
# 100 is meeting the assessed level's expectations, 200 is demonstrating
# the next level's in full.
class Assessments::ScoreSummary
  # The coverage count the category header and the chip bar use — the ONE
  # definition, so an agent's "4 of 9 rated" matches the screen's.
  include Views::Assessments::Concerns::RatedCount

  # @param assignment [PersonFrameworkAssignment]
  # @param context [Symbol] :self, :manager or :alignment — the viewer's
  #   perspective, resolved by the caller exactly as the web resolves it
  def initialize(assignment:, context:)
    @assignment = assignment
    @context = context
  end

  # @return [Hash] `{ scale:, score:, state:, components:, thresholds:,
  #   promotion_ready:, blocked:, categories: }`
  def overall
    {
      scale: scale,
      score: percent(scoring[:components][:score]),
      state: scoring[:performance_state].to_s,
      components: components_payload(scoring[:components]),
      thresholds: thresholds_payload,
      promotion_ready: scoring.dig(:promotion_readiness, :eligible) || false,
      blocked: blocked_payload,
      categories: categories_payload
    }
  end

  # One capability's score, the same shape one altitude down.
  #
  # @param stable_id [String]
  # @return [Hash, nil] nil when the capability isn't bound to the role
  def capability(stable_id)
    components = scoring.dig(:capability_scores, stable_id)
    return nil unless components

    {
      scale: scale,
      score: components[:scorable] ? percent(components[:score]) : nil,
      # No expectation at the assessed level means no verdict either — the
      # card says "No expectation at E3" rather than calling someone
      # underperforming at something nobody asked of them.
      state: components[:scorable] ? components[:state].to_s : nil,
      components: components_payload(components),
      has_expectation_at_assessed_level: components[:scorable],
      blocked: scoring[:capability_statuses]&.dig(stable_id) == :blocked,
      block_reason: scoring.dig(:block_reasons, stable_id)
    }
  end

  private

  def matrix_data
    @matrix_data ||= Assessments::MatrixDataBuilder.new(
      framework: @assignment.framework,
      role: FrameworkState::Role.find_by!(role_id: @assignment.role_id),
      level: FrameworkState::Level.find_by!(level_id: @assignment.level_id),
      person_id: @assignment.person_id,
      cycle_id: @assignment.current_open_cycle&.cycle_id,
      categories: eager_loaded_categories,
      participant_status: @assignment.current_open_cycle_participation&.status,
      context: @context,
      # No viewer — the builder then loads no evidence and no comments at
      # all. A score reads neither, and this runs on a request that wants
      # numbers, not a page.
      viewer_person_id: nil,
      viewer_sees_all_evidence: false
    ).build
  end

  def eager_loaded_categories
    FrameworkState::CapabilityCategory
      .where(framework_id: @assignment.framework_id, status: "active")
      # The builder reads each expectation's illustrations while building
      # cells, so leaving them out here is ~300 extra queries on a real
      # framework for data no score reads.
      .includes(capabilities: [ :bindings, { expectations: :illustrations } ])
      .order(:ordinal)
  end

  # The perspective the viewer's own screen renders — NOT the builder's
  # `:effective` fallback chain, which for a manager blends in the
  # assessee's self ratings and would hand an agent a different number
  # from the one on the page they are discussing.
  def scoring
    @scoring ||= perspective_scoring || matrix_data[:scoring]
  end

  # Falls back to the effective chain only when that perspective has no
  # ratings at all — exactly what the views do, so the fallback can't
  # diverge either.
  def perspective_scoring
    case @context
    when :self      then matrix_data[:self_scoring]
    when :manager   then matrix_data[:manager_scoring]
    when :alignment then matrix_data[:aligned_scoring]
    end
  end

  # What the numbers mean, in the client's own payload — an agent that
  # reads "132" needs the scale spelled out or it will read it as 132% of
  # something it invents.
  def scale
    {
      unit: "percent_of_assessed_level_expectations",
      assessed_level: matrix_data[:level].code,
      next_level: next_level_code,
      meaning: next_level_code ?
        "100 = meeting #{matrix_data[:level].code} expectations in full; " \
        "200 = demonstrating #{next_level_code} expectations in full (promotion ready)" :
        "100 = meeting #{matrix_data[:level].code} expectations in full; this is the top of the ladder"
    }
  end

  def next_level_code
    @next_level_code ||= matrix_data[:merged_levels]
      .select { |l| l[:ordinal] > matrix_data[:person_level] }
      .min_by { |l| l[:ordinal] }
      &.dig(:level_code)
  end

  # The score's three parts, so a client can say WHY a number is what it
  # is: what share of the assessed level is demonstrated, how far into the
  # bands above, and what is still missing below.
  def components_payload(components)
    {
      assessed_level: percent(components[:current]),
      above_assessed_level: percent(components[:next]),
      missing_below_assessed_level: percent(1.0 - components[:prior].to_f),
      bands_above: components[:bands_above]
    }
  end

  # The framework's own bands, so a client can name a state without
  # hard-coding 80/95/150 — a tenant can move any of them.
  def thresholds_payload
    {
      underperforming: percent(
        @assignment.framework.underperforming_threshold&.to_f ||
          PersonDevelopment::Scoring::DEFAULT_UNDERPERFORMING_THRESHOLD
      ),
      meeting: percent(matrix_data[:meeting_expectation_threshold]),
      mastering: percent(matrix_data[:mastery_threshold])
    }
  end

  def blocked_payload
    (scoring[:block_reasons] || {}).map do |stable_id, reason|
      { capability_stable_id: stable_id, name: capability_names[stable_id], reason: reason }
    end
  end

  def categories_payload
    matrix_data[:categories].map do |cat_data|
      category = cat_data[:category]
      # Every category the builder returns has at least one bound
      # capability (it drops the rest), so it always has components.
      components = scoring.fetch(:category_scores).fetch(category.category_id)
      counts = category_rated_count(cat_data, @context)
      {
        id: category.category_id,
        name: category.name,
        score: components[:scorable] ? percent(components[:score]) : nil,
        state: components[:scorable] ? components[:state].to_s : nil,
        components: components_payload(components),
        rated_at_assessed_level: counts[:rated],
        total_at_assessed_level: counts[:total]
      }
    end
  end

  def capability_names
    @capability_names ||= matrix_data[:categories].flat_map { |c| c[:capabilities] }
      .to_h { |cap| [ cap[:capability].stable_id, cap[:capability].name ] }
  end

  def percent(value)
    (value.to_f * 100).round(0)
  end
end
