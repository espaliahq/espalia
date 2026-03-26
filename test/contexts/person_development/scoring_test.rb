# frozen_string_literal: true

require "test_helper"

# Unit tests for PersonDevelopment::Scoring.
#
# Uses plain Ruby structs to avoid database dependency — the Scoring class
# is deliberately pure Ruby.
#
class PersonDevelopment::ScoringTest < ActiveSupport::TestCase
  # Minimal duck-typed objects for test setup
  Rating = Struct.new(:capability_stable_id, :level_ordinal,
    :aligned_frequency, :manager_rated_frequency, :self_rated_frequency,
    keyword_init: true)

  CapStub = Struct.new(:stable_id, :category_id, keyword_init: true)

  BindingStub = Struct.new(:capability_id, :weight, :deficit_threshold, :overperformance_cap,
    :capability, keyword_init: true)

  CategoryStub = Struct.new(:category_id, :deficit_threshold,
    :overperformance_cap, keyword_init: true)

  CAP_A = "cap-a"
  CAP_B = "cap-b"
  CAT_1 = "cat-1"
  CAT_2 = "cat-2"

  # Builds a simple single-capability scorer.
  #
  # @param person_level [Integer]
  # @param all_levels [Array<Integer>]
  # @param ratings [Array<Rating>]
  # @param weight [Numeric]
  # @param deficit_threshold [Numeric, nil]
  # @param category_deficit_threshold [Numeric, nil]
  # @param thresholds [Hash]
  def build_scorer(person_level:, all_levels:, ratings: [], weight: 1.0,
                   deficit_threshold: nil, category_deficit_threshold: nil, thresholds: {})
    cap = CapStub.new(stable_id: CAP_A, category_id: CAT_1)
    binding = BindingStub.new(capability_id: "bid", weight: weight,
      deficit_threshold: deficit_threshold, overperformance_cap: nil, capability: cap)
    category = CategoryStub.new(category_id: CAT_1,
      deficit_threshold: category_deficit_threshold, overperformance_cap: nil)

    PersonDevelopment::Scoring.new(
      level_ratings: ratings,
      bindings: [ binding ],
      categories: [ category ],
      person_level: person_level,
      all_level_ordinals: all_levels,
      thresholds: thresholds
    )
  end

  # ── Effective frequency fallback chain ──

  context "effective frequency" do
    should "use aligned_frequency first" do
      r = Rating.new(capability_stable_id: CAP_A, level_ordinal: 3,
        aligned_frequency: "consistent", manager_rated_frequency: "some",
        self_rated_frequency: "occasional")
      scorer = build_scorer(person_level: 3, all_levels: [ 1, 2, 3 ], ratings: [ r ])
      # aligned=consistent → 1.0; expected=1.0 → contribution 0 at L3
      # L1, L2 unrated but <=3 → default 1.0; contribution 0 each
      assert_equal 0.0, scorer.performance_ratio - 1.0
    end

    should "fall back to manager_rated_frequency when no alignment" do
      r = Rating.new(capability_stable_id: CAP_A, level_ordinal: 3,
        aligned_frequency: nil, manager_rated_frequency: "occasional",
        self_rated_frequency: "consistent")
      scorer = build_scorer(person_level: 3, all_levels: [ 3 ], ratings: [ r ])
      # occasional=0.5, expected=1.0 → contribution -0.5 * 1.0 = -0.5
      # baseline = 1 level * weight 1.0 = 1.0
      assert_in_delta(-0.5, scorer.performance_ratio - 1.0, 0.01)
    end

    should "fall back to self_rated_frequency when no manager rating" do
      r = Rating.new(capability_stable_id: CAP_A, level_ordinal: 3,
        aligned_frequency: nil, manager_rated_frequency: nil,
        self_rated_frequency: "some")
      scorer = build_scorer(person_level: 3, all_levels: [ 3 ], ratings: [ r ])
      # some=0.25, expected=1.0 → contribution -0.75
      assert_in_delta(0.25, scorer.performance_ratio, 0.01)
    end

    should "treat 'none' as 0.0 frequency, overriding default for below-level" do
      # Person at L3, L2 rated "none" → overrides default 1.0 assumption
      r = Rating.new(capability_stable_id: CAP_A, level_ordinal: 2,
        aligned_frequency: nil, manager_rated_frequency: nil, self_rated_frequency: "none")
      scorer = build_scorer(person_level: 3, all_levels: [ 2, 3 ], ratings: [ r ])
      # L2: none=0.0, expected=1.0 → contribution -1.0
      # L3: unrated at current → 0.0, expected=1.0 → contribution -1.0
      # baseline = 2 * 1.0 = 2.0; ratio = (-2.0 + 2.0) / 2.0 = 0.0
      assert_in_delta(0.0, scorer.performance_ratio, 0.01)
    end

    should "default to 1.0 for levels below person_level when unrated" do
      scorer = build_scorer(person_level: 3, all_levels: [ 1, 2 ], ratings: [])
      # Levels 1-2 (below person_level=3) default consistent → contribution 0
      # No level at person_level itself → ratio = 1.0
      assert_in_delta(1.0, scorer.performance_ratio, 0.01)
    end

    should "default to 0.0 at current level when unrated" do
      scorer = build_scorer(person_level: 3, all_levels: [ 3 ], ratings: [])
      # Level 3 = person_level, unrated → default 0.0, expected 1.0 → contribution -1.0
      # baseline = 1 * 1.0 = 1.0; ratio = (−1.0 + 1.0) / 1.0 = 0.0
      assert_in_delta(0.0, scorer.performance_ratio, 0.01)
    end

    should "default to 0.0 for levels > person_level when unrated" do
      scorer = build_scorer(person_level: 3, all_levels: [ 1, 2, 3, 4 ], ratings: [])
      # Levels 1-2: default 1.0 (consistent, expected) → contribution 0
      # Level 3: unrated at current level → 0.0, expected 1.0 → contribution -1.0
      # Level 4: default 0.0, expected 0.0 → contribution 0
      # baseline = 3 * 1.0 = 3.0; ratio = (−1.0 + 3.0) / 3.0 = 0.67
      assert_in_delta(2.0 / 3.0, scorer.performance_ratio, 0.01)
    end
  end

  # ── Contribution formula ──

  context "scoring formula" do
    should "produce positive contribution when exceeding expectations" do
      ratings = [
        Rating.new(capability_stable_id: CAP_A, level_ordinal: 3,
          aligned_frequency: "consistent", manager_rated_frequency: nil, self_rated_frequency: nil),
        Rating.new(capability_stable_id: CAP_A, level_ordinal: 4,
          aligned_frequency: "consistent", manager_rated_frequency: nil, self_rated_frequency: nil)
      ]
      scorer = build_scorer(person_level: 3, all_levels: [ 1, 2, 3, 4 ], ratings: ratings)
      # L1-2: default 1.0, L3: rated consistent, L4: rated consistent vs expected 0.0 → +1.0
      # baseline = 3 * 1.0 = 3.0
      assert_in_delta(4.0 / 3.0, scorer.performance_ratio, 0.01)
    end

    should "produce negative contribution when below expectations" do
      r = Rating.new(capability_stable_id: CAP_A, level_ordinal: 3,
        aligned_frequency: "some", manager_rated_frequency: nil, self_rated_frequency: nil)
      scorer = build_scorer(person_level: 3, all_levels: [ 3 ], ratings: [ r ])
      # some=0.25, expected=1.0 → contribution -0.75
      assert_in_delta(0.25, scorer.performance_ratio, 0.01)
    end

    should "weight contributions by binding weight" do
      cap = CapStub.new(stable_id: CAP_A, category_id: CAT_1)
      binding = BindingStub.new(capability_id: "bid", weight: 2.0,
        deficit_threshold: nil, overperformance_cap: nil, capability: cap)
      category = CategoryStub.new(category_id: CAT_1,
        deficit_threshold: nil, overperformance_cap: nil)

      r = Rating.new(capability_stable_id: CAP_A, level_ordinal: 1,
        aligned_frequency: "occasional", manager_rated_frequency: nil, self_rated_frequency: nil)

      scorer = PersonDevelopment::Scoring.new(
        level_ratings: [ r ],
        bindings: [ binding ],
        categories: [ category ],
        person_level: 1,
        all_level_ordinals: [ 1 ]
      )
      # occasional=0.5, expected=1.0 → contribution -0.5 * 2.0 = -1.0
      # baseline = 1 * 2.0 = 2.0 → ratio = 1.0 / 2.0 = 0.5
      assert_in_delta(0.5, scorer.performance_ratio, 0.01)
    end
  end

  # ── Category pass/fail ──

  context "#category_results" do
    should "pass when pool >= -category deficit_threshold" do
      r = Rating.new(capability_stable_id: CAP_A, level_ordinal: 3,
        aligned_frequency: "consistent", manager_rated_frequency: nil, self_rated_frequency: nil)
      scorer = build_scorer(person_level: 3, all_levels: [ 3 ], ratings: [ r ],
        category_deficit_threshold: 0.5)
      result = scorer.category_results[CAT_1]
      assert result[:pass]
      assert_in_delta(0.0, result[:pool], 0.01)
    end

    should "fail when net contribution exceeds category deficit_threshold" do
      # Category deficit_threshold=0 (must balance).
      # Capability rated "some" → raw = -0.75 → net = -0.75
      # -0.75 >= 0 → false → fails
      r = Rating.new(capability_stable_id: CAP_A, level_ordinal: 3,
        aligned_frequency: "some", manager_rated_frequency: nil, self_rated_frequency: nil)
      scorer = build_scorer(person_level: 3, all_levels: [ 3 ], ratings: [ r ],
        category_deficit_threshold: 0)
      result = scorer.category_results[CAT_1]
      assert_not result[:pass]
    end

    should "use framework default when category deficit_threshold is nil" do
      r = Rating.new(capability_stable_id: CAP_A, level_ordinal: 3,
        aligned_frequency: "some", manager_rated_frequency: nil, self_rated_frequency: nil)
      # some=0.25, expected=1.0 → pool = -0.75; framework default threshold=1.0
      # -0.75 >= -1.0 → passes
      scorer = build_scorer(person_level: 3, all_levels: [ 3 ], ratings: [ r ],
        category_deficit_threshold: nil)
      result = scorer.category_results[CAT_1]
      assert result[:pass]
    end

    should "fail when pool passes but a capability is blocked" do
      # Two capabilities in same category, deficit_threshold=0 (must balance).
      # cap_a rated "some" at L3 → raw = -0.75; deficit at L3 = 0.75 > 0 → :blocked
      # cap_b rated consistent at L3 AND L4 → raw = 0 + 1.0 = +1.0
      # net = -0.75 + 1.0 = +0.25 >= 0 → pool passes, but blocked cap fails category
      cap_a = CapStub.new(stable_id: CAP_A, category_id: CAT_1)
      cap_b = CapStub.new(stable_id: CAP_B, category_id: CAT_1)
      binding_a = BindingStub.new(capability_id: "bid-a", weight: 1.0,
        deficit_threshold: nil, overperformance_cap: nil, capability: cap_a)
      binding_b = BindingStub.new(capability_id: "bid-b", weight: 1.0,
        deficit_threshold: nil, overperformance_cap: nil, capability: cap_b)
      category = CategoryStub.new(category_id: CAT_1,
        deficit_threshold: 0, overperformance_cap: nil)

      ratings = [
        Rating.new(capability_stable_id: CAP_A, level_ordinal: 3,
          aligned_frequency: "some", manager_rated_frequency: nil, self_rated_frequency: nil),
        Rating.new(capability_stable_id: CAP_B, level_ordinal: 3,
          aligned_frequency: "consistent", manager_rated_frequency: nil, self_rated_frequency: nil),
        Rating.new(capability_stable_id: CAP_B, level_ordinal: 4,
          aligned_frequency: "consistent", manager_rated_frequency: nil, self_rated_frequency: nil)
      ]

      scorer = PersonDevelopment::Scoring.new(
        level_ratings: ratings,
        bindings: [ binding_a, binding_b ],
        categories: [ category ],
        person_level: 3,
        all_level_ordinals: [ 3, 4 ]
      )
      result = scorer.category_results[CAT_1]
      assert_not result[:pass]
      assert_in_delta(0.25, result[:pool], 0.01)
    end

    should "pass when pool passes and no capabilities are blocked" do
      # Two capabilities in same category, deficit_threshold=0 (must balance).
      # Both rated consistent at L3 → no deficit → no blocking
      # net pool = 0.0 >= 0 → passes
      cap_a = CapStub.new(stable_id: CAP_A, category_id: CAT_1)
      cap_b = CapStub.new(stable_id: CAP_B, category_id: CAT_1)
      binding_a = BindingStub.new(capability_id: "bid-a", weight: 1.0,
        deficit_threshold: nil, overperformance_cap: nil, capability: cap_a)
      binding_b = BindingStub.new(capability_id: "bid-b", weight: 1.0,
        deficit_threshold: nil, overperformance_cap: nil, capability: cap_b)
      category = CategoryStub.new(category_id: CAT_1,
        deficit_threshold: 0, overperformance_cap: nil)

      ratings = [
        Rating.new(capability_stable_id: CAP_A, level_ordinal: 3,
          aligned_frequency: "consistent", manager_rated_frequency: nil, self_rated_frequency: nil),
        Rating.new(capability_stable_id: CAP_B, level_ordinal: 3,
          aligned_frequency: "consistent", manager_rated_frequency: nil, self_rated_frequency: nil)
      ]

      scorer = PersonDevelopment::Scoring.new(
        level_ratings: ratings,
        bindings: [ binding_a, binding_b ],
        categories: [ category ],
        person_level: 3,
        all_level_ordinals: [ 3 ]
      )
      result = scorer.category_results[CAT_1]
      assert result[:pass]
      assert_in_delta(0.0, result[:pool], 0.01)
    end
  end

  # ── Mastery ──

  context "#meeting_expectations?" do
    should "return true when rated consistent at current level" do
      r = Rating.new(capability_stable_id: CAP_A, level_ordinal: 3,
        aligned_frequency: "consistent", manager_rated_frequency: nil, self_rated_frequency: nil)
      scorer = build_scorer(person_level: 3, all_levels: [ 3 ], ratings: [ r ])
      assert scorer.meeting_expectations?
    end

    should "return false when performance_ratio < 1.0" do
      r = Rating.new(capability_stable_id: CAP_A, level_ordinal: 3,
        aligned_frequency: "occasional", manager_rated_frequency: nil, self_rated_frequency: nil)
      scorer = build_scorer(person_level: 3, all_levels: [ 3 ], ratings: [ r ])
      # ratio = 0.5 < 1.0
      assert_not scorer.meeting_expectations?
    end
  end

  context "#mastering?" do
    should "default to 1.15 threshold when no mastery_threshold configured" do
      scorer = build_scorer(person_level: 3, all_levels: [ 3 ])
      # unrated → default 1.0 → ratio 1.0; 1.0 < 1.15 → not mastering
      assert_not scorer.mastering?
    end

    should "return true when performance_ratio meets explicit threshold" do
      r = Rating.new(capability_stable_id: CAP_A, level_ordinal: 3,
        aligned_frequency: "consistent", manager_rated_frequency: nil, self_rated_frequency: nil)
      scorer = build_scorer(person_level: 3, all_levels: [ 3 ], ratings: [ r ],
        thresholds: { mastery_threshold: 0.8 })
      assert scorer.mastering?  # consistent → ratio 1.0 >= 0.8
    end

    should "return false when performance_ratio below threshold" do
      r = Rating.new(capability_stable_id: CAP_A, level_ordinal: 3,
        aligned_frequency: "some", manager_rated_frequency: nil, self_rated_frequency: nil)
      scorer = build_scorer(person_level: 3, all_levels: [ 3 ], ratings: [ r ],
        thresholds: { mastery_threshold: 0.8 })
      # ratio = 0.25 < 0.8
      assert_not scorer.mastering?
    end

    should "return true when exceeding default 1.15 threshold" do
      # Rate consistent at current level and above to exceed expectations
      ratings = [
        Rating.new(capability_stable_id: CAP_A, level_ordinal: 3,
          aligned_frequency: "consistent", manager_rated_frequency: nil, self_rated_frequency: nil),
        Rating.new(capability_stable_id: CAP_A, level_ordinal: 4,
          aligned_frequency: "consistent", manager_rated_frequency: nil, self_rated_frequency: nil)
      ]
      scorer = build_scorer(person_level: 3, all_levels: [ 1, 2, 3, 4 ], ratings: ratings)
      # L1-2 default 1.0 (contribution 0), L3 consistent (contribution 0),
      # L4 1.0 vs expected 0.0 → +1.0
      # baseline = 3 * 1.0 = 3.0; ratio = 4.0 / 3.0 = 1.33 >= 1.15
      assert scorer.mastering?
    end
  end

  # ── Agreed level ──

  context "#agreed_level_for" do
    should "return the highest level_ordinal where effective_frequency is consistent" do
      ratings = [
        Rating.new(capability_stable_id: CAP_A, level_ordinal: 3,
          aligned_frequency: "consistent", manager_rated_frequency: nil, self_rated_frequency: nil),
        Rating.new(capability_stable_id: CAP_A, level_ordinal: 4,
          aligned_frequency: "occasional", manager_rated_frequency: nil, self_rated_frequency: nil)
      ]
      scorer = build_scorer(person_level: 3, all_levels: [ 1, 2, 3, 4 ], ratings: ratings)
      # Levels 1, 2 default to 1.0 (consistent); level 3 aligned consistent; level 4 occasional
      assert_equal 3, scorer.agreed_level_for(CAP_A)
    end

    should "return nil when no level has consistent effective_frequency" do
      r = Rating.new(capability_stable_id: CAP_A, level_ordinal: 3,
        aligned_frequency: "some", manager_rated_frequency: nil, self_rated_frequency: nil)
      scorer = build_scorer(person_level: 2, all_levels: [ 3 ], ratings: [ r ])
      assert_nil scorer.agreed_level_for(CAP_A)
    end
  end

  # ── Column header scoring (performance_ratio_at_level) ──

  context "#performance_ratio_at_level" do
    should "score identically for unrated and explicitly consistent at levels below current" do
      # Person is L3. At L1 (below current), unrated should default to consistent.
      # Explicitly rating L1 as consistent should produce the same score.
      scorer_unrated = build_scorer(person_level: 3, all_levels: [ 1 ], ratings: [])
      scorer_rated = build_scorer(person_level: 3, all_levels: [ 1 ], ratings: [
        Rating.new(capability_stable_id: CAP_A, level_ordinal: 1,
          aligned_frequency: "consistent", manager_rated_frequency: nil, self_rated_frequency: nil)
      ])

      assert_in_delta(
        scorer_rated.performance_ratio_at_level(1),
        scorer_unrated.performance_ratio_at_level(1),
        0.001,
        "Unrated below current level should score the same as explicitly consistent"
      )
    end
  end

  # ── Level verdict (unified column header + promotion code path) ──

  context "#level_verdict" do
    should "return :meeting when ratio meets threshold and no blocked capabilities" do
      r = Rating.new(capability_stable_id: CAP_A, level_ordinal: 3,
        aligned_frequency: "consistent", manager_rated_frequency: nil, self_rated_frequency: nil)
      scorer = build_scorer(person_level: 3, all_levels: [ 3 ], ratings: [ r ])
      assert_equal :meeting, scorer.level_verdict(3)
    end

    should "return :mastering when ratio meets mastery threshold and no blocked capabilities" do
      ratings = [
        Rating.new(capability_stable_id: CAP_A, level_ordinal: 3,
          aligned_frequency: "consistent", manager_rated_frequency: nil, self_rated_frequency: nil),
        Rating.new(capability_stable_id: CAP_A, level_ordinal: 4,
          aligned_frequency: "consistent", manager_rated_frequency: nil, self_rated_frequency: nil)
      ]
      scorer = build_scorer(person_level: 3, all_levels: [ 1, 2, 3, 4 ], ratings: ratings)
      # ratio = 4/3 = 1.33 >= 1.15 mastery threshold
      assert_equal :mastering, scorer.level_verdict(3)
    end

    should "return :below when ratio meets threshold but a capability is blocked" do
      # deficit_threshold=0 (mandatory) + unrated at reference level → blocked
      cap = CapStub.new(stable_id: CAP_A, category_id: CAT_1)
      cap_b = CapStub.new(stable_id: CAP_B, category_id: CAT_1)
      # mandatory capability (deficit_threshold=0) — unrated will block
      binding_a = BindingStub.new(capability_id: "bid-a", weight: 0.5,
        deficit_threshold: 0.0, overperformance_cap: nil, capability: cap)
      # non-mandatory capability rated consistent — lifts overall ratio
      binding_b = BindingStub.new(capability_id: "bid-b", weight: 1.5,
        deficit_threshold: nil, overperformance_cap: nil, capability: cap_b)
      category = CategoryStub.new(category_id: CAT_1,
        deficit_threshold: nil, overperformance_cap: nil)

      ratings = [
        Rating.new(capability_stable_id: CAP_B, level_ordinal: 3,
          aligned_frequency: "consistent", manager_rated_frequency: nil, self_rated_frequency: nil)
      ]
      # cap_a unrated at L3: deficit = 1.0 * 0.5 = 0.5 > 0.0 threshold → blocked
      # Overall ratio still high enough from cap_b → but verdict should be :below
      scorer = PersonDevelopment::Scoring.new(
        level_ratings: ratings, bindings: [ binding_a, binding_b ],
        categories: [ category ], person_level: 3, all_level_ordinals: [ 3 ]
      )
      assert_equal :below, scorer.level_verdict(3)
    end
  end

  # ── Promotion readiness ──

  context "#promotion_readiness" do
    should "be eligible when deficit_threshold=0 cap is consistent at next level and score meets threshold" do
      cap = CapStub.new(stable_id: CAP_A, category_id: CAT_1)
      binding = BindingStub.new(capability_id: "bid", weight: 1.0,
        deficit_threshold: 0.0, overperformance_cap: nil, capability: cap)  # mandatory (no deficit)
      category = CategoryStub.new(category_id: CAT_1,
        deficit_threshold: nil, overperformance_cap: nil)

      r = Rating.new(capability_stable_id: CAP_A, level_ordinal: 4,
        aligned_frequency: "consistent", manager_rated_frequency: nil, self_rated_frequency: nil)

      scorer = PersonDevelopment::Scoring.new(
        level_ratings: [ r ],
        bindings: [ binding ],
        categories: [ category ],
        person_level: 3,
        all_level_ordinals: [ 1, 2, 3, 4 ],
        thresholds: { meeting_expectation_threshold: 0.7 }
      )
      result = scorer.promotion_readiness
      assert result[:eligible]
      assert result[:meets_score_threshold]
      assert_empty result[:blocked_at_next_level]
    end

    should "not be eligible when deficit_threshold=0 cap is not rated at next level" do
      cap = CapStub.new(stable_id: CAP_A, category_id: CAT_1)
      binding = BindingStub.new(capability_id: "bid", weight: 1.0,
        deficit_threshold: 0.0, overperformance_cap: nil, capability: cap)  # mandatory (no deficit)
      category = CategoryStub.new(category_id: CAT_1,
        deficit_threshold: nil, overperformance_cap: nil)

      scorer = PersonDevelopment::Scoring.new(
        level_ratings: [],
        bindings: [ binding ],
        categories: [ category ],
        person_level: 3,
        all_level_ordinals: [ 1, 2, 3, 4 ]
      )
      result = scorer.promotion_readiness
      assert_not result[:eligible]
      assert_includes result[:blocked_at_next_level], CAP_A
    end

    should "not block standard capabilities (deficit_threshold=nil) when unrated at next level" do
      # With default threshold 1.0, unrated at next level gives deficit = 1.0.
      # Using strict > comparison: 1.0 > 1.0 = false → not blocked.
      # Score penalty still applies via performance_ratio_at_level.
      cap = CapStub.new(stable_id: CAP_A, category_id: CAT_1)
      binding = BindingStub.new(capability_id: "bid", weight: 1.0,
        deficit_threshold: nil, overperformance_cap: nil, capability: cap)
      category = CategoryStub.new(category_id: CAT_1,
        deficit_threshold: nil, overperformance_cap: nil)

      scorer = PersonDevelopment::Scoring.new(
        level_ratings: [],
        bindings: [ binding ],
        categories: [ category ],
        person_level: 3,
        all_level_ordinals: [ 1, 2, 3, 4 ]
      )
      result = scorer.promotion_readiness
      assert_empty result[:blocked_at_next_level]
    end
  end
end
