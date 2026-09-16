# frozen_string_literal: true

# Calculates capability assessment scores for a person against a role.
#
# Pure Ruby class — no ActiveRecord dependency. Accepts plain data objects
# and returns structured scoring results.
#
# == The scale (ADR-21)
#
# One level-independent scale, read the same way at every level of every
# role:
#
#   1.00  meeting the current level's expectations — every bound capability
#         consistent at the assessed level (weighted)
#   1.50  halfway to the next level
#   2.00  demonstrating the next level in full — promotion ready
#
# Below 1.0 the number is the share of the current level demonstrated.
#
# == Components
#
#   band(o)   = Σ weight over bindings that carry an expectation at level o
#   f(b, o)   = frequency value for capability b at level o (see
#               effective_frequency: unrated defaults to 1.0 below the assessed
#               level and to 0.0 at or above it)
#
#   prior   = Σ_{o < L} Σ_b weight·f(b,o) / Σ_{o < L} band(o)    (1.0 when no prior levels)
#   current = Σ_b weight·f(b,L) / band(L)
#   next    = Σ_{k ≤ cap} Σ_b weight·gate(b,k)·f(b,L+k) / band(L+k)
#
#   score   = current + next + (prior − 1)
#
# Prior levels are pooled into one bucket the size of a single band, so a
# deficit rated below the assessed level subtracts from the score without
# the number of prior levels ever entering the arithmetic — that padding is
# what made the previous ratio level-dependent.
#
# == The progression gate
#
# Credit above the assessed level is discounted per capability by how
# consistently that same capability is shown at the assessed level, so a
# capability cannot "make up" a gap at its own level with a rating above it:
#
#   flexible binding (tolerance > 0):  gate = f(b, L)           (multiplicative)
#   mandatory binding (tolerance 0):   gate = 1 if f(b, L) ≥ 1.0 else 0   (step)
#
# For a cap of 2 or more the factor chains along the levels (credit at L+2 is
# gated by L and by L+1). Making up across DIFFERENT capabilities stays
# allowed — that is what the weighted average is — bounded by the
# per-capability deficit threshold (blocking) and the category gates.
#
# The mandatory case is a step because with a multiplicative gate a
# mandatory capability at "most of the time" with "consistently" above nets
# to zero, is never blocked, and the one rule written for it is defeated.
#
# == Over-performance cap
#
#   Resolved per capability: binding.overperformance_cap ||
#     category.overperformance_cap || framework.overperformance_cap (default 1)
#   A window of levels: ordinals beyond reference_level + cap contribute 0.
#   Because gated credit is monotone along the chain, the window is also the
#   most a capability can earn — cap 1 → a 2.0 ceiling, cap 2 → 3.0, cap 0 → 1.0.
#   A capability's share of a band is structural (it has an expectation
#   there); a binding capped below the framework's cap holds its share at 0.
#
# == Deficit threshold (blocking)
#
#   Resolved per capability: binding.deficit_threshold ||
#     category.deficit_threshold || framework.deficit_threshold (default 0.75)
#
#   contribution = Σ (f − expected) × weight across capped ordinals, with
#                  above-level credit gated as above
#   deficit      = max(0, −contribution)
#   Verdict gate: deficit > threshold → capability is :blocked
#
#   At the default 0.75 a current-level "not yet" (deficit 1.0) blocks; "some"
#   and "most of the time" can be made up elsewhere. Tolerance 0 marks the
#   capability mandatory ("Required").
#
# == Category gate
#
#   category_threshold = category.deficit_threshold || framework.deficit_threshold
#   pass if net_contribution >= -category_threshold AND no capability blocked
#
# == Verdicts
#
#   meeting_expectations? = score >= meeting_expectation_threshold AND no :blocked
#   mastering?            = score >= mastery_threshold AND no :blocked
#   promotion_readiness   = the same score evaluated with L+1 as the reference
#                           level >= meeting_expectation_threshold AND no
#                           :blocked capabilities at L+1
#
#   `performance_ratio` IS `performance_ratio_at_level(person_level)` — one
#   formula, so the hero, the level chips and promotion readiness can never
#   disagree.
#
# == Agreed level
#
#   Highest level_ordinal where effective_frequency == "consistent" (1.0).
#
class PersonDevelopment::Scoring
  FREQUENCY = { "none" => 0.0, "some" => 0.25, "occasional" => 0.5, "consistent" => 1.0 }.freeze
  DEFAULT_MASTERY_THRESHOLD              = 1.50
  DEFAULT_MEETING_EXPECTATION_THRESHOLD  = 0.95
  DEFAULT_UNDERPERFORMING_THRESHOLD      = 0.80
  DEFAULT_OVERPERFORMANCE_CAP        = 1
  DEFAULT_DEFICIT_THRESHOLD          = 0.75

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
  # @param person_level [Integer] the assessed level ordinal (the cycle's
  #   enrollment snapshot, see ADR-19)
  # @param all_level_ordinals [Array<Integer>] all level ordinals in the role's ladder
  # @param expectation_cells [Enumerable<Array(String, Integer)>, nil] the
  #   (capability_stable_id, level_ordinal) pairs that carry a behavioural
  #   expectation. A band is normalised over the capabilities that have an
  #   expectation at that level, so a capability with no next-level
  #   expectation neither earns nor owes next-level credit. nil means every
  #   binding has an expectation at every ordinal.
  # @param thresholds [Hash] optional overrides: mastery_threshold:,
  #   meeting_expectation_threshold:, underperforming_threshold:,
  #   overperformance_cap:, deficit_threshold:
  # @param perspective [Symbol] which frequency field to use (:effective, :self_only,
  #   :manager_only, :aligned_only)
  def initialize(level_ratings:, bindings:, categories:, person_level:, all_level_ordinals:,
                 expectation_cells: nil, thresholds: {}, perspective: :effective)
    @level_ratings = index_ratings(level_ratings)
    @bindings = bindings
    @categories = categories.index_by(&:category_id)
    @person_level = person_level
    @all_level_ordinals = all_level_ordinals.sort
    @expectation_cells = expectation_cells&.to_set
    @perspective = perspective
    @mastery_threshold              = thresholds[:mastery_threshold]              || DEFAULT_MASTERY_THRESHOLD
    @meeting_expectation_threshold  = thresholds[:meeting_expectation_threshold]  || DEFAULT_MEETING_EXPECTATION_THRESHOLD
    @underperforming_threshold      = thresholds[:underperforming_threshold]      || DEFAULT_UNDERPERFORMING_THRESHOLD
    @default_overperformance_cap  = thresholds[:overperformance_cap]    || DEFAULT_OVERPERFORMANCE_CAP
    @default_deficit_threshold    = thresholds[:deficit_threshold]      || DEFAULT_DEFICIT_THRESHOLD
  end

  # Category pass/fail results.
  #
  # @return [Hash{String => Hash}] category_id => { pass: bool, pool: Float }
  def category_results
    @category_results ||= compute_category_results
  end

  # The score on the level-independent scale: 1.0 = meeting the assessed
  # level, 2.0 = demonstrating the next level in full (see the class docs).
  # Identical to `performance_ratio_at_level(person_level)`.
  #
  # @return [Float]
  def performance_ratio
    components[:score]
  end

  # The score broken into the three parts the hero copy names — the share
  # of the assessed level demonstrated, the progress into the next band(s),
  # and the pooled attainment at prior levels (1.0 when none, or none rated
  # down).
  #
  # @return [Hash] { prior: Float, current: Float, next: Float, score: Float }
  def components
    @components ||= components_at(@person_level)
  end

  # Whether the person is meeting expectations at their current level.
  #
  # @return [Boolean]
  def meeting_expectations?
    performance_ratio >= @meeting_expectation_threshold && !any_blocked?(@person_level)
  end

  # Whether the person is past the mastery waypoint on the way to the next
  # level (default: halfway, 1.5). Blocked capabilities prevent mastery
  # regardless of score.
  #
  # @return [Boolean]
  def mastering?
    performance_ratio >= @mastery_threshold && !any_blocked?(@person_level)
  end

  # Unified performance state for the assessment narrative, picked so the
  # hero always points at the *next milestone* — never at one already
  # cleared.
  #
  #   :underperforming — score < underperforming_threshold (0.80)
  #   :progressing     — score < meeting_expectation_threshold (0.95) OR any
  #                      capability blocked → the milestone is still the
  #                      current level's bar
  #   :top_of_ladder   — meeting, and the role has no level above this one:
  #                      there is no next band to progress into
  #   :eligible        — meets the next level's expectations (promotion
  #                      ready) → past the last gate
  #   :mastering       — score ≥ mastery_threshold (1.50: more than halfway
  #                      to the next level) and not yet eligible
  #   :performing      — meeting, below the mastery waypoint → the milestone
  #                      is progress toward the next level
  #
  # Precedence: underperforming → progressing → top_of_ladder → eligible →
  # mastering → performing.
  #
  # @return [Symbol]
  def performance_state
    @performance_state ||= compute_performance_state
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
  # :blocked     — deficit > effective_deficit_threshold (blocks meeting/mastery/promotion)
  # :above_cap   — consistent at ordinals beyond reference_level + overperformance_cap
  # :at_bar      — effective_freq at reference_level >= 1.0 (consistent)
  # :developing  — below bar, not blocked
  #
  # @param reference_level [Integer] defaults to person's assessed level
  # @return [Hash{String => Symbol}] stable_id => status
  def capability_statuses(reference_level: @person_level)
    @capability_statuses ||= {}
    @capability_statuses[reference_level] ||= compute_capability_statuses(reference_level)
  end

  # The score as if the person's assessed level were +reference_level+ —
  # the same formula, so a column header, promotion readiness and the hero
  # read one number.
  #
  # @param reference_level [Integer] the level ordinal to score against
  # @return [Float] 1.0 = meeting expectations at that level
  def performance_ratio_at_level(reference_level)
    components_at(reference_level)[:score]
  end

  # Unified verdict for a given reference level: combines the score
  # threshold AND capability blocking into a single status. Used by column
  # headers, promotion readiness, and the hero — one code path.
  #
  # @param reference_level [Integer] the level ordinal to evaluate
  # @return [Symbol] :mastering, :meeting, or :below
  def level_verdict(reference_level)
    ratio = performance_ratio_at_level(reference_level)
    has_blocked = any_blocked?(reference_level)

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
  # @param reference_level [Integer] defaults to person's assessed level
  # @return [Hash{String => String}] stable_id => reason string (only blocked capabilities)
  def block_reasons(reference_level: @person_level)
    @block_reasons ||= {}
    @block_reasons[reference_level] ||= compute_block_reasons(reference_level)
  end

  # Promotion readiness result. Eligible when the score evaluated at the
  # next level meets meeting_expectation_threshold AND no capabilities are
  # blocked there. With the default cap of 1 that is "score ≥ 1.95 and
  # nothing blocked at L+1".
  #
  # @return [Hash] { eligible: bool, meets_score_threshold: bool,
  #   blocked_at_next_level: Array<String> (stable_ids) }
  def promotion_readiness
    @promotion_readiness ||= compute_promotion_readiness
  end

  # Highest level ordinal at which the person meets the expectation threshold.
  #
  # @return [Integer, nil]
  def inferred_level
    @inferred_level ||= @all_level_ordinals.reverse.detect do |ordinal|
      performance_ratio_at_level(ordinal) >= @meeting_expectation_threshold
    end
  end

  # Raw total contribution for a single binding at the person's assessed
  # level, in weight units: deficits below and at the level, plus gated
  # credit above it. Drives the per-capability deltas and the block gate.
  #
  # @param binding [#capability_id, #weight, #capability]
  # @return [Float]
  def raw_contribution(binding)
    raw_contribution_at_level(binding, @person_level)
  end

  # Whether the role has a level above the person's assessed one. False at
  # the top of the ladder — there is then no next band to progress into.
  #
  # @return [Boolean]
  def has_next_level?
    @all_level_ordinals.any? { |o| o > @person_level }
  end

  # Contribution evaluated against the next level above the person's
  # current — what the contribution would be if their assessed level were
  # @person_level + 1. Used to surface which capabilities still need work
  # for promotion.
  #
  # @param binding [#capability_id, #weight, #capability]
  # @return [Float]
  def next_level_contribution(binding)
    raw_contribution_at_level(binding, @person_level + 1)
  end

  private

  # ── Core computation ──

  # The three components (and their sum) evaluated with +reference_level+
  # as the assessed level.
  #
  # @return [Hash] { prior:, current:, next:, score: }
  def components_at(reference_level)
    @components_at ||= {}
    @components_at[reference_level] ||= begin
      prior   = prior_attainment(reference_level)
      current = attainment_at(reference_level)
      nxt     = next_band_progress(reference_level)
      # Floored at 0: a prior-level "not yet" on top of nothing at the
      # assessed level would otherwise read as a negative share.
      score   = current.nil? ? 0.0 : [ current + nxt + (prior - 1.0), 0.0 ].max
      { prior: prior, current: current || 0.0, next: nxt, score: score }
    end
  end

  # Weighted frequency attainment at one level over the bindings that
  # carry an expectation there. nil when no binding does (unscorable).
  #
  # @return [Float, nil]
  def attainment_at(ordinal)
    band = @bindings.select { |b| cell?(b.capability.stable_id, ordinal) }
    weight = band.sum { |b| b.weight.to_f }
    return nil unless weight.positive?

    band.sum { |b| b.weight.to_f * effective_frequency(b.capability.stable_id, ordinal) } / weight
  end

  # Pooled attainment across every prior level's cells — one bucket, so the
  # count of prior levels never scales the deficit. 1.0 when there is
  # nothing below the reference level.
  #
  # @return [Float]
  def prior_attainment(reference_level)
    total = 0.0
    weight = 0.0
    @all_level_ordinals.each do |ordinal|
      next unless ordinal < reference_level

      @bindings.each do |b|
        sid = b.capability.stable_id
        next unless cell?(sid, ordinal)

        total += b.weight.to_f * effective_frequency(sid, ordinal)
        weight += b.weight.to_f
      end
    end
    weight.positive? ? total / weight : 1.0
  end

  # Gated, cap-windowed progress into the band(s) above the reference
  # level, each band normalised over the capabilities with an expectation
  # there. 0.0 at the top of the ladder.
  #
  # @return [Float]
  def next_band_progress(reference_level)
    max_cap = @bindings.map { |b| overperformance_cap_for(b) }.max || 0
    (1..max_cap).sum do |k|
      ordinal = reference_level + k
      band = @bindings.select { |b| cell?(b.capability.stable_id, ordinal) }
      weight = band.sum { |b| b.weight.to_f }
      next 0.0 unless weight.positive?

      credit = band.sum do |b|
        next 0.0 if overperformance_cap_for(b) < k

        b.weight.to_f * progression_gate(b, reference_level, k) *
          effective_frequency(b.capability.stable_id, ordinal)
      end
      credit / weight
    end
  end

  # The discount applied to credit k levels above the reference level:
  # the product of the gate factor at each level in between.
  #
  # @return [Float] 0.0..1.0
  def progression_gate(binding, reference_level, k)
    sid = binding.capability.stable_id
    (0...k).reduce(1.0) do |gate, j|
      gate * gate_factor(binding, effective_frequency(sid, reference_level + j))
    end
  end

  # Step for a mandatory binding (resolved tolerance 0), the frequency
  # itself for a flexible one. See the class docs.
  #
  # @return [Float]
  def gate_factor(binding, frequency)
    if deficit_threshold_for(binding).zero?
      frequency >= FREQUENCY["consistent"] ? 1.0 : 0.0
    else
      frequency
    end
  end

  # Total contribution for a single binding evaluated against a reference
  # level, in weight units: (f − 1) at and below the level, gated f above
  # it, ordinals beyond reference_level + cap excluded.
  #
  # @param binding [#capability_id, #weight, #capability]
  # @param reference_level [Integer]
  # @return [Float]
  def raw_contribution_at_level(binding, reference_level)
    stable_id = binding.capability.stable_id
    cap       = overperformance_cap_for(binding)
    weight    = binding.weight.to_f

    @all_level_ordinals.sum do |ordinal|
      next 0.0 unless cell?(stable_id, ordinal)
      next 0.0 if ordinal > reference_level + cap

      freq = effective_frequency(stable_id, ordinal)
      if ordinal <= reference_level
        (freq - 1.0) * weight
      else
        progression_gate(binding, reference_level, ordinal - reference_level) * freq * weight
      end
    end
  end

  def compute_category_results
    pools = Hash.new(0.0)
    @bindings.each do |binding|
      cat_id = binding.capability.category_id
      pools[cat_id] += raw_contribution(binding)
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

  def any_blocked?(reference_level)
    capability_statuses(reference_level: reference_level).values.any? { |s| s == :blocked }
  end

  # See {#performance_state} for the state vocabulary + precedence.
  def compute_performance_state
    ratio       = performance_ratio
    has_blocked = any_blocked?(@person_level)

    return :underperforming if ratio < @underperforming_threshold
    return :progressing     if ratio < @meeting_expectation_threshold || has_blocked
    return :top_of_ladder   unless has_next_level?
    return :eligible        if promotion_readiness[:eligible]
    return :mastering       if ratio >= @mastery_threshold

    :performing
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

      reasons[stable_id] = format_block_reason(deficit, threshold)
    end
  end

  def format_block_reason(deficit, threshold)
    if threshold.zero?
      "Below expectations by #{'%.1f' % deficit} points — no deficit allowed"
    else
      "Below expectations by #{'%.1f' % deficit} points (max allowed: #{'%.1f' % threshold})"
    end
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

  # Whether a behavioural expectation exists for the capability at the level.
  def cell?(stable_id, ordinal)
    @expectation_cells.nil? || @expectation_cells.include?([ stable_id, ordinal ])
  end

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
