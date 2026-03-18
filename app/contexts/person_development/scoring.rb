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
#     default: 1.0 for level_ordinal <= person_level (assume consistent)
#              0.0 for level_ordinal >  person_level (not expected)
#
#   expected_at_level = (level_ordinal <= person_level) ? 1.0 : 0.0
#   contribution_at_level = (effective_frequency - expected_at_level) * weight
#   total_contribution = sum of contribution_at_level across all levels
#
# == Category pass/fail
#
#   capped = individual_tolerance.present? ?
#     max(total_contribution, -individual_tolerance) : total_contribution
#   category_pool += capped
#   pass if category_pool >= -(category_tolerance || Infinity)
#
# == Overall score
#
#   Uses raw (uncapped) contributions — individual_tolerance does not hide
#   deficits from the overall signal.
#
# == Agreed level
#
#   Highest level_ordinal where effective_frequency == "consistent" (1.0).
#
class PersonDevelopment::Scoring
  FREQUENCY = { "some" => 0.25, "occasional" => 0.5, "consistent" => 1.0 }.freeze
  DEFAULT_MASTERY_THRESHOLD = 1.25
  DEFAULT_PROMOTION_SCORE_THRESHOLD = 0.9

  # @param level_ratings [Array<#capability_stable_id, #level_ordinal,
  #   #aligned_frequency, #manager_rated_frequency, #self_rated_frequency>]
  #   AssessmentLevelRating records (or duck-typed objects) for the person
  # @param bindings [Array<#capability_id, #weight, #individual_tolerance,
  #   #capability (responds to #stable_id, #category_id)>]
  #   CapabilityRoleBinding records for the role, with capability preloaded
  # @param categories [Array<#category_id, #category_tolerance>]
  #   CapabilityCategory records for the framework
  # @param person_level [Integer] person's assigned level ordinal
  # @param all_level_ordinals [Array<Integer>] all level ordinals in the framework
  # @param thresholds [Hash] optional overrides: mastery_threshold:,
  #   promotion_score_threshold:
  def initialize(level_ratings:, bindings:, categories:, person_level:, all_level_ordinals:, thresholds: {})
    @level_ratings = index_ratings(level_ratings)
    @bindings = bindings
    @categories = categories.index_by(&:category_id)
    @person_level = person_level
    @all_level_ordinals = all_level_ordinals.sort
    @mastery_threshold = thresholds[:mastery_threshold] || DEFAULT_MASTERY_THRESHOLD
    @promotion_score_threshold = thresholds[:promotion_score_threshold] || DEFAULT_PROMOTION_SCORE_THRESHOLD
  end

  # Category pass/fail results using capped (individual_tolerance-limited) contributions.
  #
  # @return [Hash{String => Hash}] category_id => { pass: bool, pool: BigDecimal }
  def category_results
    @category_results ||= compute_category_results
  end

  # Ratio of actual performance to baseline.
  # baseline_score = sum of (expected_level_count * weight) per capability
  # (i.e. what a person scores if consistently at their level for all caps → ratio = 1.0)
  # Above expectations → ratio > 1.0; below → ratio < 1.0.
  #
  # raw_score is a deviation sum, so the actual absolute score is
  # raw_score + baseline_score.
  #
  # @return [Float]
  def performance_ratio
    @performance_ratio ||= baseline_score.positive? ? (raw_score + baseline_score) / baseline_score : 0.0
  end

  # Whether the person is meeting expectations at their current level.
  # True when performance_ratio >= 1.0 (at or above baseline).
  #
  # @return [Boolean]
  def meeting_expectations?
    performance_ratio >= 1.0
  end

  # Whether the person is mastering their current level (significantly exceeding).
  # Defaults to 1.25 threshold when not explicitly configured.
  #
  # @return [Boolean]
  def mastering?
    performance_ratio >= @mastery_threshold
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

  # Promotion readiness result.
  # Structural check: all must-have capabilities at person_level + 1 must have
  # effective_frequency == "consistent". Score check: raw_score against the
  # next-level baseline must meet promotion_score_threshold.
  #
  # @return [Hash] { eligible: bool, meets_score_threshold: bool,
  #   mandatory_next_level_gaps: Array<String> (stable_ids) }
  def promotion_readiness
    @promotion_readiness ||= compute_promotion_readiness
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
      # Baseline: consistently at expected level for all levels <= person_level
      @all_level_ordinals.count { |o| o <= @person_level } * binding.weight.to_f
    end
  end

  # Raw (uncapped) total contribution for a single binding at the person's current level.
  #
  # @param binding [#capability_id, #weight, #individual_tolerance, #capability]
  # @return [Float]
  def raw_contribution(binding)
    raw_contribution_at_level(binding, @person_level)
  end

  # Raw (uncapped) total contribution for a single binding evaluated against
  # a given reference level. Used by promotion to evaluate against next level.
  #
  # @param binding [#capability_id, #weight, #individual_tolerance, #capability]
  # @param reference_level [Integer] the level ordinal to use for expectations
  # @return [Float]
  def raw_contribution_at_level(binding, reference_level)
    stable_id = binding.capability.stable_id
    @all_level_ordinals.sum do |ordinal|
      freq = effective_frequency(stable_id, ordinal)
      expected = ordinal <= reference_level ? 1.0 : 0.0
      (freq - expected) * binding.weight.to_f
    end
  end

  # Capped contribution for category pool: individual_tolerance caps the deficit.
  #
  # @param binding [#capability_id, #weight, #individual_tolerance, #capability]
  # @return [Float]
  def capped_contribution(binding)
    raw = raw_contribution(binding)
    tol = binding.individual_tolerance&.to_f
    tol ? [ raw, -tol ].max : raw
  end

  def compute_category_results
    pools = Hash.new(0.0)
    @bindings.each do |binding|
      cat_id = binding.capability.category_id
      pools[cat_id] += capped_contribution(binding)
    end

    pools.transform_values do |pool|
      # category_tolerance nil => no gate (always passes)
    end

    @bindings.map { |b| b.capability.category_id }.uniq.to_h do |cat_id|
      cat = @categories[cat_id]
      pool = pools[cat_id]
      tolerance = cat&.category_tolerance&.to_f
      pass = tolerance.nil? || pool >= -tolerance
      [ cat_id, { pass: pass, pool: pool } ]
    end
  end

  def compute_promotion_readiness
    next_level = @person_level + 1
    gaps = []

    @bindings.each do |binding|
      next unless binding.mandatory?

      stable_id = binding.capability.stable_id
      freq = effective_frequency(stable_id, next_level)
      gaps << stable_id if freq < FREQUENCY["consistent"]
    end

    # Recompute contributions as if person_level were next_level.
    # At next_level, the expectation is "consistent" for all ordinals ≤ next_level,
    # so contributions are relative to the next-level baseline, not current.
    next_raw_score = @bindings.sum { |binding| raw_contribution_at_level(binding, next_level) }
    next_baseline = @bindings.sum do |binding|
      @all_level_ordinals.count { |o| o <= next_level } * binding.weight.to_f
    end
    score_ratio = next_baseline.positive? ? (next_raw_score + next_baseline) / next_baseline : 0.0
    meets_score = score_ratio >= @promotion_score_threshold

    {
      eligible: gaps.empty? && meets_score,
      meets_score_threshold: meets_score,
      mandatory_next_level_gaps: gaps
    }
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
  # Fallback: aligned → manager → self → default.
  #
  # @param stable_id [String]
  # @param level_ordinal [Integer]
  # @return [Float]
  def effective_frequency(stable_id, level_ordinal)
    rating = @level_ratings[[ stable_id, level_ordinal ]]

    value = rating&.aligned_frequency ||
            rating&.manager_rated_frequency ||
            rating&.self_rated_frequency

    if value
      FREQUENCY.fetch(value, 0.0)
    elsif level_ordinal <= @person_level
      1.0  # default: assume consistent for unassessed past levels
    else
      0.0  # default: not expected, not assessed
    end
  end
end
