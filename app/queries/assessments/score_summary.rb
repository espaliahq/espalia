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
# 100 is meeting the assessed level's expectations, and a further 100 per
# band the over-performance cap allows above it.
#
# **The screen's honesty gates travel with the number.** Every altitude
# reports `scored:`, and when it is false the numbers are nil with an
# `unscored_reason` — the payload equivalent of the hero's "Rate yourself
# to see your score", the category header's "score unlocks at 2" and a
# card's "Not rated". Without them an agent would read 12% off an
# assessment the person has not started and report it as a verdict.
class Assessments::ScoreSummary
  # The coverage count the category header and the chip bar use — the ONE
  # definition, so an agent's "4 of 9 rated" matches the screen's.
  include Views::Assessments::Concerns::RatedCount

  COVERAGE_UNLOCK_THRESHOLD = Views::Assessments::HeroSummary::COVERAGE_UNLOCK_THRESHOLD

  # @param assignment [PersonFrameworkAssignment]
  # @param context [Symbol] :self, :manager or :alignment — the viewer's
  #   perspective, resolved by the caller exactly as the web resolves it
  # @param lens [Assessments::Lens, nil, :home] the role and level to read
  #   against (ADR-22); `:home` resolves the assignment's own. nil — a home
  #   role or level that is gone — reports `assignment_structure_unavailable`.
  def initialize(assignment:, context:, lens: :home)
    @assignment = assignment
    @context = context
    @lens = lens == :home ? home_lens : lens
  end

  # @return [Hash] `{ scale:, score:, state:, components:, thresholds:,
  #   promotion_ready:, blocked:, unrated:, categories: }`
  def overall
    return unscorable_overall unless scorable_assignment?

    scored = overall_scored?
    {
      lens: @lens.payload,
      scale: scale,
      scored: scored,
      unscored_reason: scored ? nil : "coverage_below_threshold",
      score: scored ? percent(scoring[:components][:score]) : nil,
      state: scored ? scoring[:performance_state].to_s : nil,
      components: scored ? components_payload(scoring[:components]) : nil,
      coverage: overall_coverage,
      thresholds: thresholds_payload,
      promotion_ready: scored && (scoring.dig(:promotion_readiness, :eligible) || false),
      blocked: blocked_payload,
      unrated: unrated_payload,
      categories: categories_payload
    }
  end

  # One capability's score, the same shape one altitude down.
  #
  # @param stable_id [String]
  # @return [Hash, nil] nil when the capability isn't bound to the role
  def capability(stable_id)
    return nil unless scorable_assignment?

    components = scoring.dig(:capability_scores, stable_id)
    return nil unless components

    # Two separate silences, and the card distinguishes them: no
    # expectation at the assessed level ("No expectation at E3") is not
    # the same as an expectation nobody has rated yet ("Not rated").
    # Either way there is no verdict to report.
    reason = capability_unscored_reason(stable_id, components)
    {
      scale: scale,
      scored: reason.nil?,
      unscored_reason: reason,
      score: reason ? nil : percent(components[:score]),
      state: reason ? nil : components[:state].to_s,
      components: reason ? nil : components_payload(components),
      has_expectation_at_assessed_level: components[:scorable],
      rated_at_assessed_level: capability_rated?(stable_id),
      blocked: scoring[:capability_statuses]&.dig(stable_id) == :blocked,
      block_reason: scoring.dig(:block_reasons, stable_id),
      weight: components[:weight],
      required: components[:required]
    }
  end

  private

  # An assignment's role and level are optional associations — a role
  # archived in a draft leaves the assignment pointing at nothing. The
  # assessment page's own lookups are strict, so there is nothing to fall
  # back to; the payload says so instead of raising through the read tool.
  def scorable_assignment?
    @lens.present?
  end

  def home_lens
    Assessments::Lens.home(@assignment)
  rescue ActiveRecord::RecordNotFound
    nil
  end

  def unscorable_overall
    {
      lens: nil, scale: nil, scored: false, unscored_reason: "assignment_structure_unavailable",
      score: nil, state: nil, components: nil, coverage: nil,
      thresholds: thresholds_payload, promotion_ready: false, blocked: [], unrated: [], categories: []
    }
  end

  # The hero's rule: below half the assessed-level cells rated there is no
  # score, with alignment exempt (individual ratings are frozen by then and
  # coverage is high by construction) and a role with no cells never stuck.
  def overall_scored?
    return true if @context == :alignment

    counts = overall_counts
    return true if counts[:total].zero?

    counts[:rated] >= (counts[:total] * COVERAGE_UNLOCK_THRESHOLD).ceil
  end

  def overall_counts
    @overall_counts ||= matrix_data[:categories]
      .map { |cat| category_rated_count(cat, @context) }
      .reduce({ rated: 0, total: 0 }) { |a, c| { rated: a[:rated] + c[:rated], total: a[:total] + c[:total] } }
  end

  def overall_coverage
    counts = overall_counts
    {
      rated_at_assessed_level: counts[:rated],
      total_at_assessed_level: counts[:total],
      # Rated cells whose value was carried from the last cycle and still
      # waits to be confirmed — "rated" but not yet this cycle's work (#480).
      to_confirm_at_assessed_level: matrix_data.dig(:current_level_work, :to_confirm).to_i,
      unlocks_at: (counts[:total] * COVERAGE_UNLOCK_THRESHOLD).ceil
    }
  end

  def capability_unscored_reason(stable_id, components)
    return "no_expectation_at_assessed_level" unless components[:scorable]
    return "not_rated_at_assessed_level" unless capability_rated?(stable_id)

    nil
  end

  # Whether the viewer's own perspective has rated this capability at the
  # assessed level — `scorable` only says an expectation exists there.
  def capability_rated?(stable_id)
    frequency_key = Views::Assessments::Concerns::RatedCount::CONTEXT_FREQUENCY_KEYS
      .fetch(@context, :current_frequency)
    capabilities_by_stable_id[stable_id]
      &.dig(:cells, matrix_data[:person_level], frequency_key)
      .present?
  end

  def capabilities_by_stable_id
    @capabilities_by_stable_id ||= matrix_data[:categories].flat_map { |c| c[:capabilities] }
      .index_by { |cap| cap[:capability].stable_id }
  end

  # The builder the web page runs, through the same lens, disclosure and
  # floor. No viewer — the builder then loads no evidence and no comments
  # at all. A score reads neither, and this runs on a request that wants
  # numbers, not a page.
  def matrix_data
    @matrix_data ||= Assessments::MatrixDataBuilder.for_lens(lens: @lens, context: @context)
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
  # hard-coding 80/95/150 — a tenant can move any of them. Read straight
  # off the framework rather than the builder's output, so an assignment
  # that cannot be scored at all still reports what the bands are.
  def thresholds_payload
    framework = @assignment.framework
    {
      underperforming: percent(framework.underperforming_threshold&.to_f ||
        PersonDevelopment::Scoring::DEFAULT_UNDERPERFORMING_THRESHOLD),
      meeting: percent(framework.meeting_expectation_threshold&.to_f ||
        PersonDevelopment::Scoring::DEFAULT_MEETING_EXPECTATION_THRESHOLD),
      mastering: percent(framework.mastery_threshold&.to_f ||
        PersonDevelopment::Scoring::DEFAULT_MASTERY_THRESHOLD)
    }
  end

  def blocked_payload
    (scoring[:block_reasons] || {}).map do |stable_id, reason|
      { capability_stable_id: stable_id, name: capability_names[stable_id], reason: reason }
    end
  end

  # Capabilities holding the state only for want of a rating — apart from
  # `blocked`, because nobody has judged them.
  def unrated_payload
    (scoring[:unrated] || []).map do |stable_id|
      { capability_stable_id: stable_id, name: capability_names[stable_id] }
    end
  end

  def categories_payload
    matrix_data[:categories].map do |cat_data|
      category = cat_data[:category]
      # Every category the builder returns has at least one bound
      # capability (it drops the rest), so it always has components.
      components = scoring.fetch(:category_scores).fetch(category.category_id)
      counts = category_rated_count(cat_data, @context)
      reason = category_unscored_reason(components, counts)
      {
        id: category.category_id,
        name: category.name,
        scored: reason.nil?,
        unscored_reason: reason,
        score: reason ? nil : percent(components[:score]),
        state: reason ? nil : components[:state].to_s,
        components: reason ? nil : components_payload(components),
        rated_at_assessed_level: counts[:rated],
        total_at_assessed_level: counts[:total],
        unlocks_at: (counts[:total] * COVERAGE_UNLOCK_THRESHOLD).ceil
      }
    end
  end

  # The category header's own gate, in fields.
  def category_unscored_reason(components, counts)
    return "no_expectation_at_assessed_level" unless components[:scorable]
    return nil if counts[:total].zero?
    return nil if counts[:rated] >= (counts[:total] * COVERAGE_UNLOCK_THRESHOLD).ceil

    "coverage_below_threshold"
  end

  def capability_names
    @capability_names ||= capabilities_by_stable_id.transform_values { |cap| cap[:capability].name }
  end

  def percent(value)
    (value.to_f * 100).round(0)
  end
end
