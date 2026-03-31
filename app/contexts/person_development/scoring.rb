# frozen_string_literal: true

# Calculates capability assessment scores for a person against a role.
#
# Pure Ruby class — no ActiveRecord dependency. Accepts plain data objects
# and returns structured scoring results.
#
# == Scoring formula (per capability, per level)
#
#   effective_frequency =
#     aligned_frequency  if present, else
#     manager_rated_frequency  if present, else
#     self_rated_frequency  if present, else
#     default: 1.0 for level_ordinal <  person_level (assume consistent for past levels)
#              0.0 for level_ordinal >= person_level (current level and above must be assessed)
#
#   expected_at_level = (level_ordinal <= person_level) ? 1.0 : 0.0
#   contribution_at_level = (effective_frequency - expected_at_level) * weight
#   total_contribution = sum of contribution_at_level across all levels,
#                        skipping ordinals > person_level + overperformance_cap
#
# == Over-performance cap
#
#   Resolved per capability: binding.overperformance_cap ||
#     category.overperformance_cap || framework.overperformance_cap (default 1)
#   Ordinals beyond person_level + cap contribute 0 to the score.
#
# == Deficit threshold
#
#   Resolved per capability: binding.deficit_threshold ||
#     category.deficit_threshold || framework.deficit_threshold (default 1.0)
#
#   contribution = Σ (effective_freq − expected) × weight across capped ordinals
#   deficit = max(0, −contribution)
#   Verdict gate: deficit > threshold → capability is :blocked
#
# == Category gate
#
#   Categories are gates on the net contribution across their capabilities.
#   Raw contributions flow through uncapped (overperformance_cap already
#   limits the positive side at the ordinal level).
#
#   category_threshold = category.deficit_threshold || framework.deficit_threshold
#   pass if net_contribution >= -category_threshold
#
# == Overall score
#
#   Uses raw (uncapped) contributions — deficit_threshold does not hide
#   deficits from the overall performance signal.
#
# == Verdicts
#
#   meeting_expectations? = performance_ratio >= meeting_expectation_threshold AND no :blocked
#   mastering?            = performance_ratio >= mastery_threshold AND no :blocked
#   promotion_readiness   = performance_ratio_at_level(next) >= meeting_expectation_threshold
#                           AND no :blocked capabilities at next level
#
# == Agreed level
#
#   Highest level_ordinal where effective_frequency == "consistent" (1.0).
#
class PersonDevelopment::Scoring
  FREQUENCY = { "none" => 0.0, "some" => 0.25, "occasional" => 0.5, "consistent" => 1.0 }.freeze
  DEFAULT_MASTERY_THRESHOLD              = 1.15
  DEFAULT_MEETING_EXPECTATION_THRESHOLD  = 0.95
  DEFAULT_OVERPERFORMANCE_CAP        = 1
  DEFAULT_DEFICIT_THRESHOLD          = 1.0

  # Perspective controls which frequency field is used for scoring.
  #
  # :effective    — fallback chain: aligned → manager → self (default, official score)
  # :self_only    — only self_rated_frequency
  # :manager_only — only manager_rated_frequency
  # :aligned_only — only aligned_frequency
  PERSPECTIVES = %i[effective self_only manager_only aligned_only].freeze

  # @param level_ratings [Array<#capability_stable_id, #level_ordinal,
  #   #aligned_frequency, #manager_rated_frequency, #self_rated_frequency>]
  #   AssessmentLevelRating records (or duck-typed objects) for the person
  # @param bindings [Array<#capability_id, #weight, #deficit_threshold,
  #   #overperformance_cap, #capability (responds to #stable_id, #category_id)>]
  #   CapabilityRoleBinding records for the role, with capability preloaded
  # @param categories [Array<#category_id, #deficit_threshold,
  #   #overperformance_cap>]
  #   CapabilityCategory records for the framework
  # @param person_level [Integer] person's assigned level ordinal
  # @param all_level_ordinals [Array<Integer>] all level ordinals in the framework
  # @param thresholds [Hash] optional overrides: mastery_threshold:,
  #   meeting_expectation_threshold:, overperformance_cap:, deficit_threshold:
  # @param perspective [Symbol] which frequency field to use (:effective, :self_only,
  #   :manager_only, :aligned_only)
  def initialize(level_ratings:, bindings:, categories:, person_level:, all_level_ordinals:, thresholds: {}, perspective: :effective)
    @level_ratings = index_ratings(level_ratings)
    @bindings = bindings
    @categories = categories.index_by(&:category_id)
    @person_level = person_level
    @all_level_ordinals = all_level_ordinals.sort
    @perspective = perspective
    @mastery_threshold              = thresholds[:mastery_threshold]              || DEFAULT_MASTERY_THRESHOLD
    @meeting_expectation_threshold  = thresholds[:meeting_expectation_threshold]  || DEFAULT_MEETING_EXPECTATION_THRESHOLD
    @default_overperformance_cap  = thresholds[:overperformance_cap]    || DEFAULT_OVERPERFORMANCE_CAP
    @default_deficit_threshold    = thresholds[:deficit_threshold]      || DEFAULT_DEFICIT_THRESHOLD
  end

  # Category pass/fail results using deficit_threshold-capped contributions.
  #
  # @return [Hash{String => Hash}] category_id => { pass: bool, pool: Float }
  def category_results
    @category_results ||= compute_category_results
  end

  # Ratio of actual performance to baseline.
  # baseline_score = sum of (expected_level_count * weight) per capability
  # (i.e. what a person scores if consistently at their level for all caps → ratio = 1.0)
  # Above expectations → ratio > 1.0; below → ratio < 1.0.
  #
  # @return [Float]
  def performance_ratio
    @performance_ratio ||= baseline_score.positive? ? (raw_score + baseline_score) / baseline_score : 0.0
  end

  # Whether the person is meeting expectations at their current level.
  # True when performance_ratio >= meeting_expectation_threshold AND no
  # capabilities are blocked.
  #
  # @return [Boolean]
  def meeting_expectations?
    performance_ratio >= @meeting_expectation_threshold && capability_statuses.values.none? { |s| s == :blocked }
  end

  # Whether the person is mastering their current level (significantly exceeding).
  # Blocked capabilities prevent mastery regardless of aggregate score.
  #
  # @return [Boolean]
  def mastering?
    performance_ratio >= @mastery_threshold && capability_statuses.values.none? { |s| s == :blocked }
  end

  # Highest level_ordinal where effective_frequency == "consistent" (1.0)
  # for the given capability.
  #
  # @param capability_stable_id [String]
  # @return [Integer, nil]
  def agreed_level_for(capability_stable_id)
    consistent_levels = @all_level_ordinals.select do |ordinal|
      effective_frequency(capability_stable_id, ordinal) >= FREQUENCY["consistent"]
    end
    consistent_levels.max
  end

  # Per-capability status at the given reference level.
  #
  # :blocked     — deficit > effective_deficit_threshold (blocks mastery/promotion)
  # :above_cap   — consistent at ordinals beyond reference_level + overperformance_cap
  # :at_bar      — effective_freq at reference_level >= 1.0 (consistent)
  # :developing  — below bar, not blocked
  #
  # @param reference_level [Integer] defaults to person's assigned level
  # @return [Hash{String => Symbol}] stable_id => status
  def capability_statuses(reference_level: @person_level)
    @capability_statuses ||= {}
    @capability_statuses[reference_level] ||= compute_capability_statuses(reference_level)
  end

  # Computes the overall performance ratio as if the person's assigned level
  # were +reference_level+. Used to show per-column expectation status in the
  # assessment matrix header and for promotion readiness.
  #
  # @param reference_level [Integer] the level ordinal to use as the baseline
  # @return [Float] ratio >= 1.0 means meeting expectations at that level
  def performance_ratio_at_level(reference_level)
    raw      = @bindings.sum { |b| raw_contribution_at_level_for_header(b, reference_level) }
    baseline = @bindings.sum do |b|
      @all_level_ordinals.count { |o| o <= reference_level } * b.weight.to_f
    end
    baseline.positive? ? (raw + baseline) / baseline : 0.0
  end

  # Unified verdict for a given reference level: combines ratio threshold
  # AND capability blocking into a single status. Used by column headers,
  # promotion readiness, and sidebar verdicts — one code path.
  #
  # @param reference_level [Integer] the level ordinal to evaluate
  # @return [Symbol] :mastering, :meeting, or :below
  def level_verdict(reference_level)
    ratio = performance_ratio_at_level(reference_level)
    has_blocked = capability_statuses(reference_level: reference_level).values.any? { |s| s == :blocked }

    if ratio >= @mastery_threshold && !has_blocked
      :mastering
    elsif ratio >= @meeting_expectation_threshold && !has_blocked
      :meeting
    else
      :below
    end
  end

  # Human-readable explanations for blocked capabilities.
  #
  # @param reference_level [Integer] defaults to person's assigned level
  # @return [Hash{String => String}] stable_id => reason string (only blocked capabilities)
  def block_reasons(reference_level: @person_level)
    @block_reasons ||= {}
    @block_reasons[reference_level] ||= compute_block_reasons(reference_level)
  end

  # Promotion readiness result.
  # Eligible when performance at next level meets meeting_expectation_threshold
  # AND no capabilities are blocked at the next level.
  #
  # @return [Hash] { eligible: bool, meets_score_threshold: bool,
  #   blocked_at_next_level: Array<String> (stable_ids) }
  def promotion_readiness
    @promotion_readiness ||= compute_promotion_readiness
  end

  # Highest level ordinal at which the person meets the expectation threshold.
  # Uses the header-path scoring (explicit_frequency at reference level).
  #
  # @return [Integer, nil]
  def inferred_level
    @inferred_level ||= @all_level_ordinals.reverse.detect do |ordinal|
      performance_ratio_at_level(ordinal) >= @meeting_expectation_threshold
    end
  end

  # Raw (uncapped) total contribution for a single binding at the person's current level.
  #
  # @param binding [#capability_id, #weight, #capability]
  # @return [Float]
  def raw_contribution(binding)
    raw_contribution_at_level(binding, @person_level)
  end

  private

  # ── Core computation ──

  # @return [Float] sum of raw (uncapped) contributions across all bound capabilities
  def raw_score
    @raw_score ||= @bindings.sum { |binding| raw_contribution(binding) }
  end

  # @return [Float] expected score when consistently meeting expectations at person_level
  def baseline_score
    @baseline_score ||= @bindings.sum do |binding|
      @all_level_ordinals.count { |o| o <= @person_level } * binding.weight.to_f
    end
  end

  # Raw (uncapped) total contribution for a single binding evaluated against
  # a given reference level. Ordinals beyond reference_level + overperformance_cap
  # contribute 0 — over-performance is capped per capability.
  #
  # @param binding [#capability_id, #weight, #capability]
  # @param reference_level [Integer] the level ordinal to use for expectations
  # @return [Float]
  def raw_contribution_at_level(binding, reference_level)
    stable_id = binding.capability.stable_id
    cap       = overperformance_cap_for(binding)

    @all_level_ordinals.sum do |ordinal|
      next 0.0 if ordinal > reference_level + cap

      freq     = effective_frequency(stable_id, ordinal)
      expected = ordinal <= reference_level ? 1.0 : 0.0
      (freq - expected) * binding.weight.to_f
    end
  end

  # Variant of raw_contribution_at_level for the column-header indicator.
  #
  # For ordinals below person_level: always uses effective_frequency (defaults
  # unrated to 1.0). These levels are assumed consistent — rating them
  # "consistent" explicitly should not change the score.
  #
  # For ordinals at or above person_level: uses effective_frequency only for
  # ordinals strictly below reference_level; at reference_level and above,
  # uses explicit_frequency (unrated = 0.0) so the indicator is not inflated
  # by capabilities the person has not yet assessed.
  #
  # @param binding [#capability_id, #weight, #capability]
  # @param reference_level [Integer]
  # @return [Float]
  def raw_contribution_at_level_for_header(binding, reference_level)
    stable_id = binding.capability.stable_id
    cap       = overperformance_cap_for(binding)

    @all_level_ordinals.sum do |ordinal|
      next 0.0 if ordinal > reference_level + cap
      freq =
        if ordinal < @person_level
          effective_frequency(stable_id, ordinal)  # default 1.0 for unrated past levels
        elsif ordinal < reference_level
          effective_frequency(stable_id, ordinal)  # rated or 0.0 (at/above person_level)
        else
          explicit_frequency(stable_id, ordinal)   # no default: unrated = 0.0
        end
      expected = ordinal <= reference_level ? 1.0 : 0.0
      (freq - expected) * binding.weight.to_f
    end
  end

  # Contribution for the category gate. Raw contributions flow through
  # uncapped — overperformance_cap already limits the positive side.
  #
  # @param binding [#capability_id, #weight, #capability]
  # @return [Float]
  def category_contribution(binding)
    raw_contribution(binding)
  end

  def compute_category_results
    pools = Hash.new(0.0)
    @bindings.each do |binding|
      cat_id = binding.capability.category_id
      pools[cat_id] += category_contribution(binding)
    end

    statuses = capability_statuses(reference_level: @person_level)

    @bindings.map { |b| b.capability.category_id }.uniq.to_h do |cat_id|
      cat       = @categories[cat_id]
      pool      = pools[cat_id]
      threshold = (cat&.deficit_threshold || @default_deficit_threshold).to_f
      has_blocked = @bindings
        .select { |b| b.capability.category_id == cat_id }
        .any? { |b| statuses[b.capability.stable_id] == :blocked }
      pass      = pool >= -threshold && !has_blocked
      [ cat_id, { pass: pass, pool: pool } ]
    end
  end

  def compute_capability_statuses(reference_level)
    @bindings.to_h do |binding|
      stable_id    = binding.capability.stable_id
      contribution = raw_contribution_at_level(binding, reference_level)
      deficit      = [ 0.0, -contribution ].max
      threshold    = deficit_threshold_for(binding)
      cap          = overperformance_cap_for(binding)
      freq         = effective_frequency(stable_id, reference_level)

      status =
        if deficit > threshold
          :blocked
        elsif @all_level_ordinals.any? { |o| o > reference_level + cap && effective_frequency(stable_id, o) >= FREQUENCY["consistent"] }
          :above_cap
        elsif freq >= FREQUENCY["consistent"]
          :at_bar
        else
          :developing
        end

      [ stable_id, status ]
    end
  end

  def compute_promotion_readiness
    next_level = @person_level + 1

    verdict     = level_verdict(next_level)
    next_ratio  = performance_ratio_at_level(next_level)
    meets_score = next_ratio >= @meeting_expectation_threshold
    blocked     = capability_statuses(reference_level: next_level).select { |_, s| s == :blocked }.keys

    {
      eligible:              verdict != :below,
      meets_score_threshold: meets_score,
      blocked_at_next_level: blocked
    }
  end

  # ── Block reason helpers ──

  def compute_block_reasons(reference_level)
    @bindings.each_with_object({}) do |binding, reasons|
      stable_id    = binding.capability.stable_id
      contribution = raw_contribution_at_level(binding, reference_level)
      deficit      = [ 0.0, -contribution ].max
      threshold    = deficit_threshold_for(binding)

      next unless deficit > threshold

      reasons[stable_id] = format_block_reason(stable_id, reference_level, contribution, threshold)
    end
  end

  def format_block_reason(stable_id, reference_level, contribution, threshold)
    deficit = [ 0.0, -contribution ].max

    if threshold.zero?
      "Below expectations by #{'%.1f' % deficit} points — no deficit allowed"
    else
      "Below expectations by #{'%.1f' % deficit} points (max allowed: #{'%.1f' % threshold})"
    end
  end

  def frequency_label(freq_value)
    FREQUENCY.key(freq_value)&.capitalize || "Unknown"
  end

  # ── Resolution helpers ──

  # Resolves the over-performance cap for a binding: binding → category → framework.
  #
  # @param binding [#overperformance_cap, #capability]
  # @return [Integer]
  def overperformance_cap_for(binding)
    binding.overperformance_cap ||
      @categories[binding.capability.category_id]&.overperformance_cap ||
      @default_overperformance_cap
  end

  # Resolves the deficit threshold for a binding: binding → category → framework.
  #
  # @param binding [#deficit_threshold, #capability]
  # @return [Float]
  def deficit_threshold_for(binding)
    (binding.deficit_threshold ||
      @categories[binding.capability.category_id]&.deficit_threshold ||
      @default_deficit_threshold).to_f
  end

  # ── Helpers ──

  # Builds a lookup index: [stable_id, level_ordinal] => rating record
  #
  # @param ratings [Array]
  # @return [Hash]
  def index_ratings(ratings)
    ratings.each_with_object({}) do |r, h|
      h[[ r.capability_stable_id, r.level_ordinal ]] = r
    end
  end

  # Returns the effective frequency multiplier for a capability at a level.
  # Respects the configured perspective to select the appropriate frequency field.
  #
  # Default only applies for levels strictly below person_level — the current
  # level must be explicitly assessed.
  #
  # @param stable_id [String]
  # @param level_ordinal [Integer]
  # @return [Float]
  def effective_frequency(stable_id, level_ordinal)
    rating = @level_ratings[[ stable_id, level_ordinal ]]
    value = frequency_value_for_perspective(rating)

    if value
      FREQUENCY.fetch(value, 0.0)
    elsif level_ordinal < @person_level
      1.0  # default: assume consistent for unassessed past levels
    else
      0.0  # default: current level and above must be explicitly assessed
    end
  end

  # Returns the explicit (rated-only) frequency for a capability at a level.
  # Unlike effective_frequency, returns 0.0 when no rating is present.
  #
  # @param stable_id [String]
  # @param level_ordinal [Integer]
  # @return [Float]
  def explicit_frequency(stable_id, level_ordinal)
    rating = @level_ratings[[ stable_id, level_ordinal ]]
    value = frequency_value_for_perspective(rating)
    value ? FREQUENCY.fetch(value, 0.0) : 0.0
  end

  # Selects the frequency value from the rating based on the configured perspective.
  #
  # @param rating [#aligned_frequency, #manager_rated_frequency, #self_rated_frequency, nil]
  # @return [String, nil]
  def frequency_value_for_perspective(rating)
    return nil unless rating

    case @perspective
    when :self_only
      rating.self_rated_frequency
    when :manager_only
      rating.manager_rated_frequency
    when :aligned_only
      rating.aligned_frequency
    else # :effective — fallback chain: aligned → manager → self
      rating.aligned_frequency ||
        rating.manager_rated_frequency ||
        rating.self_rated_frequency
    end
  end
end
