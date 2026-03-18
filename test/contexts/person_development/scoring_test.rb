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

  BindingStub = Struct.new(:capability_id, :weight, :individual_tolerance, :capability,
    keyword_init: true) do
    def mandatory?
      individual_tolerance&.zero?
    end
  end

  CategoryStub = Struct.new(:category_id, :category_tolerance, keyword_init: true)

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
  # @param individual_tolerance [Numeric, nil]
  # @param category_tolerance [Numeric, nil]
  # @param thresholds [Hash]
  def build_scorer(person_level:, all_levels:, ratings: [], weight: 1.0,
                   individual_tolerance: nil, category_tolerance: nil, thresholds: {})
    cap = CapStub.new(stable_id: CAP_A, category_id: CAT_1)
    binding = BindingStub.new(capability_id: "bid", weight: weight,
      individual_tolerance: individual_tolerance, capability: cap)
    category = CategoryStub.new(category_id: CAT_1, category_tolerance: category_tolerance)

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

    should "default to 1.0 for levels <= person_level when unrated" do
      scorer = build_scorer(person_level: 3, all_levels: [ 1, 2, 3 ], ratings: [])
      # All 3 levels default consistent → contribution 0 each
      assert_in_delta(1.0, scorer.performance_ratio, 0.01)
    end

    should "default to 0.0 for levels > person_level when unrated" do
      scorer = build_scorer(person_level: 3, all_levels: [ 1, 2, 3, 4 ], ratings: [])
      # Levels 1-3: default 1.0 (consistent, expected) → contribution 0
      # Level 4: default 0.0, expected 0.0 → contribution 0
      assert_in_delta(1.0, scorer.performance_ratio, 0.01)
    end
  end

  # ── Contribution formula ──

  context "scoring formula" do
    should "produce positive contribution when exceeding expectations" do
      r = Rating.new(capability_stable_id: CAP_A, level_ordinal: 4,
        aligned_frequency: "consistent", manager_rated_frequency: nil, self_rated_frequency: nil)
      scorer = build_scorer(person_level: 3, all_levels: [ 1, 2, 3, 4 ], ratings: [ r ])
      # L1-3: default 1.0, expected 1.0 → 0 each
      # L4: freq=1.0, expected=0.0 → contribution +1.0 * weight 1.0 = +1.0
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
        individual_tolerance: nil, capability: cap)
      category = CategoryStub.new(category_id: CAT_1, category_tolerance: nil)

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
    should "pass when pool >= -category_tolerance" do
      r = Rating.new(capability_stable_id: CAP_A, level_ordinal: 3,
        aligned_frequency: "consistent", manager_rated_frequency: nil, self_rated_frequency: nil)
      scorer = build_scorer(person_level: 3, all_levels: [ 3 ], ratings: [ r ],
        category_tolerance: 0.5)
      result = scorer.category_results[CAT_1]
      assert result[:pass]
      assert_in_delta(0.0, result[:pool], 0.01)
    end

    should "fail when pool < -category_tolerance" do
      r = Rating.new(capability_stable_id: CAP_A, level_ordinal: 3,
        aligned_frequency: "some", manager_rated_frequency: nil, self_rated_frequency: nil)
      # some=0.25, expected=1.0 → pool = -0.75; tolerance=0 → fails
      scorer = build_scorer(person_level: 3, all_levels: [ 3 ], ratings: [ r ],
        category_tolerance: 0)
      result = scorer.category_results[CAT_1]
      assert_not result[:pass]
    end

    should "pass when category_tolerance is nil (no gate)" do
      r = Rating.new(capability_stable_id: CAP_A, level_ordinal: 3,
        aligned_frequency: "some", manager_rated_frequency: nil, self_rated_frequency: nil)
      scorer = build_scorer(person_level: 3, all_levels: [ 3 ], ratings: [ r ],
        category_tolerance: nil)
      result = scorer.category_results[CAT_1]
      assert result[:pass]
    end

    should "cap individual deficit at individual_tolerance before pooling" do
      # Two capabilities: cap_a has individual_tolerance: 0.3, so its -0.75 deficit
      # is capped at -0.3. With category_tolerance: 0.5, pool = -0.3 → passes.
      cap_a = CapStub.new(stable_id: CAP_A, category_id: CAT_1)
      binding_a = BindingStub.new(capability_id: "bid-a", weight: 1.0,
        individual_tolerance: 0.3, capability: cap_a)
      category = CategoryStub.new(category_id: CAT_1, category_tolerance: 0.5)

      r = Rating.new(capability_stable_id: CAP_A, level_ordinal: 3,
        aligned_frequency: "some", manager_rated_frequency: nil, self_rated_frequency: nil)

      scorer = PersonDevelopment::Scoring.new(
        level_ratings: [ r ],
        bindings: [ binding_a ],
        categories: [ category ],
        person_level: 3,
        all_level_ordinals: [ 3 ]
      )
      result = scorer.category_results[CAT_1]
      assert result[:pass]
      assert_in_delta(-0.3, result[:pool], 0.01)
    end
  end

  # ── Mastery ──

  context "#meeting_expectations?" do
    should "return true when performance_ratio >= 1.0" do
      scorer = build_scorer(person_level: 3, all_levels: [ 3 ])
      assert scorer.meeting_expectations?  # unrated → default 1.0 → ratio 1.0
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
    should "default to 1.25 threshold when no mastery_threshold configured" do
      scorer = build_scorer(person_level: 3, all_levels: [ 3 ])
      # unrated → default 1.0 → ratio 1.0; 1.0 < 1.25 → not mastering
      assert_not scorer.mastering?
    end

    should "return true when performance_ratio meets explicit threshold" do
      scorer = build_scorer(person_level: 3, all_levels: [ 3 ],
        thresholds: { mastery_threshold: 0.8 })
      assert scorer.mastering?  # unrated → default 1.0 → ratio 1.0 >= 0.8
    end

    should "return false when performance_ratio below threshold" do
      r = Rating.new(capability_stable_id: CAP_A, level_ordinal: 3,
        aligned_frequency: "some", manager_rated_frequency: nil, self_rated_frequency: nil)
      scorer = build_scorer(person_level: 3, all_levels: [ 3 ], ratings: [ r ],
        thresholds: { mastery_threshold: 0.8 })
      # ratio = 0.25 < 0.8
      assert_not scorer.mastering?
    end

    should "return true when exceeding default 1.25 threshold" do
      # Rate above person level to exceed expectations
      r = Rating.new(capability_stable_id: CAP_A, level_ordinal: 4,
        aligned_frequency: "consistent", manager_rated_frequency: nil, self_rated_frequency: nil)
      scorer = build_scorer(person_level: 3, all_levels: [ 1, 2, 3, 4 ], ratings: [ r ])
      # L1-3 default 1.0 (contribution 0), L4 1.0 vs expected 0.0 → +1.0
      # baseline = 3 * 1.0 = 3.0; ratio = 4.0 / 3.0 = 1.33 >= 1.25
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

  # ── Promotion readiness ──

  context "#promotion_readiness" do
    should "be eligible when all mandatory next-level caps are consistent and score meets threshold" do
      cap = CapStub.new(stable_id: CAP_A, category_id: CAT_1)
      binding = BindingStub.new(capability_id: "bid", weight: 1.0,
        individual_tolerance: 0, capability: cap)  # mandatory
      category = CategoryStub.new(category_id: CAT_1, category_tolerance: nil)

      r = Rating.new(capability_stable_id: CAP_A, level_ordinal: 4,
        aligned_frequency: "consistent", manager_rated_frequency: nil, self_rated_frequency: nil)

      scorer = PersonDevelopment::Scoring.new(
        level_ratings: [ r ],
        bindings: [ binding ],
        categories: [ category ],
        person_level: 3,
        all_level_ordinals: [ 1, 2, 3, 4 ],
        thresholds: { promotion_score_threshold: 0.7 }
      )
      result = scorer.promotion_readiness
      assert result[:eligible]
      assert result[:meets_score_threshold]
      assert_empty result[:mandatory_next_level_gaps]
    end

    should "not be eligible when mandatory cap at next level is not consistent" do
      cap = CapStub.new(stable_id: CAP_A, category_id: CAT_1)
      binding = BindingStub.new(capability_id: "bid", weight: 1.0,
        individual_tolerance: 0, capability: cap)  # mandatory
      category = CategoryStub.new(category_id: CAT_1, category_tolerance: nil)

      scorer = PersonDevelopment::Scoring.new(
        level_ratings: [],
        bindings: [ binding ],
        categories: [ category ],
        person_level: 3,
        all_level_ordinals: [ 1, 2, 3, 4 ]
      )
      result = scorer.promotion_readiness
      assert_not result[:eligible]
      assert_includes result[:mandatory_next_level_gaps], CAP_A
    end

    should "skip non-mandatory caps in structural check" do
      cap = CapStub.new(stable_id: CAP_A, category_id: CAT_1)
      binding = BindingStub.new(capability_id: "bid", weight: 1.0,
        individual_tolerance: nil, capability: cap)  # not mandatory
      category = CategoryStub.new(category_id: CAT_1, category_tolerance: nil)

      scorer = PersonDevelopment::Scoring.new(
        level_ratings: [],
        bindings: [ binding ],
        categories: [ category ],
        person_level: 3,
        all_level_ordinals: [ 1, 2, 3, 4 ]
      )
      result = scorer.promotion_readiness
      assert_empty result[:mandatory_next_level_gaps]
    end
  end
end
