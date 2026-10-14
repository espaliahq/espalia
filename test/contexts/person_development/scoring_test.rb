# frozen_string_literal: true

require "test_helper"

# Unit tests for PersonDevelopment::Scoring — the level-independent scale
# (ADR-21): 1.0 = meeting the assessed level, 2.0 = demonstrating the next
# level in full.
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

  # An aligned rating for CAP_A (or the given capability) at a level.
  def rated(level, frequency, cap: CAP_A)
    Rating.new(capability_stable_id: cap, level_ordinal: level,
      aligned_frequency: frequency, manager_rated_frequency: nil, self_rated_frequency: nil)
  end

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
                   deficit_threshold: nil, category_deficit_threshold: nil,
                   overperformance_cap: nil, expectation_cells: nil, thresholds: {}, home_level: nil)
    cap = CapStub.new(stable_id: CAP_A, category_id: CAT_1)
    binding = BindingStub.new(capability_id: "bid", weight: weight,
      deficit_threshold: deficit_threshold, overperformance_cap: overperformance_cap, capability: cap)
    category = CategoryStub.new(category_id: CAT_1,
      deficit_threshold: category_deficit_threshold, overperformance_cap: nil)

    PersonDevelopment::Scoring.new(
      level_ratings: ratings,
      bindings: [ binding ],
      categories: [ category ],
      person_level: person_level,
      all_level_ordinals: all_levels,
      expectation_cells: expectation_cells,
      thresholds: thresholds,
      home_level: home_level
    )
  end

  # Two capabilities in one category, with per-binding tolerances.
  def build_pair(person_level:, all_levels:, ratings:, tolerance_a: nil, tolerance_b: nil,
                 weight_a: 1.0, weight_b: 1.0, category_deficit_threshold: nil, thresholds: {},
                 cap_a_limit: nil, cap_b_limit: nil)
    cap_a = CapStub.new(stable_id: CAP_A, category_id: CAT_1)
    cap_b = CapStub.new(stable_id: CAP_B, category_id: CAT_1)
    binding_a = BindingStub.new(capability_id: "bid-a", weight: weight_a,
      deficit_threshold: tolerance_a, overperformance_cap: cap_a_limit, capability: cap_a)
    binding_b = BindingStub.new(capability_id: "bid-b", weight: weight_b,
      deficit_threshold: tolerance_b, overperformance_cap: cap_b_limit, capability: cap_b)
    category = CategoryStub.new(category_id: CAT_1,
      deficit_threshold: category_deficit_threshold, overperformance_cap: nil)

    PersonDevelopment::Scoring.new(
      level_ratings: ratings,
      bindings: [ binding_a, binding_b ],
      categories: [ category ],
      person_level: person_level,
      all_level_ordinals: all_levels,
      expectation_cells: nil,
      thresholds: thresholds
    )
  end

  # ── Defaults ──

  context "defaults" do
    should "put the mastery waypoint halfway to the next level" do
      assert_equal 1.50, PersonDevelopment::Scoring::DEFAULT_MASTERY_THRESHOLD
    end

    should "block on a current-level 'not yet' but not on 'some of the time'" do
      assert_equal 0.75, PersonDevelopment::Scoring::DEFAULT_DEFICIT_THRESHOLD
    end
  end

  # ── Effective frequency fallback chain ──

  context "effective frequency" do
    should "use aligned_frequency first" do
      r = Rating.new(capability_stable_id: CAP_A, level_ordinal: 3,
        aligned_frequency: "consistent", manager_rated_frequency: "some",
        self_rated_frequency: "occasional")
      scorer = build_scorer(person_level: 3, all_levels: [ 1, 2, 3 ], ratings: [ r ])
      assert_in_delta(1.0, scorer.performance_ratio, 0.001)
    end

    should "fall back to manager_rated_frequency when no alignment" do
      r = Rating.new(capability_stable_id: CAP_A, level_ordinal: 3,
        aligned_frequency: nil, manager_rated_frequency: "occasional",
        self_rated_frequency: "consistent")
      scorer = build_scorer(person_level: 3, all_levels: [ 3 ], ratings: [ r ])
      assert_in_delta(0.5, scorer.performance_ratio, 0.001)
    end

    should "fall back to self_rated_frequency when no manager rating" do
      r = Rating.new(capability_stable_id: CAP_A, level_ordinal: 3,
        aligned_frequency: nil, manager_rated_frequency: nil,
        self_rated_frequency: "some")
      scorer = build_scorer(person_level: 3, all_levels: [ 3 ], ratings: [ r ])
      assert_in_delta(0.25, scorer.performance_ratio, 0.001)
    end

    should "assume consistent for unrated levels below the assessed level" do
      scorer = build_scorer(person_level: 3, all_levels: [ 1, 2, 3 ], ratings: [ rated(3, "consistent") ])
      assert_in_delta(1.0, scorer.components[:prior], 0.001)
      assert_in_delta(1.0, scorer.performance_ratio, 0.001)
    end

    should "treat 'none' as 0.0, overriding the below-level default" do
      # L2 rated "none" pulls the pooled prior attainment down.
      scorer = build_scorer(person_level: 3, all_levels: [ 1, 2, 3 ],
        ratings: [ rated(2, "none"), rated(3, "consistent") ])
      assert_in_delta(0.5, scorer.components[:prior], 0.001)
      assert_in_delta(0.5, scorer.performance_ratio, 0.001)
    end

    should "default to 0.0 at the assessed level when unrated" do
      scorer = build_scorer(person_level: 3, all_levels: [ 3 ], ratings: [])
      assert_in_delta(0.0, scorer.performance_ratio, 0.001)
    end

    should "default to 0.0 above the assessed level when unrated" do
      scorer = build_scorer(person_level: 3, all_levels: [ 1, 2, 3, 4 ], ratings: [ rated(3, "consistent") ])
      assert_in_delta(0.0, scorer.components[:next], 0.001)
      assert_in_delta(1.0, scorer.performance_ratio, 0.001)
    end
  end

  # ── The home-level floor (ADR-22) ──

  context "the home-level floor" do
    should "not assume the levels between home and a lens above it" do
      # Home E2, read as E4: L1 is still assumed, L2 and L3 are not.
      scorer = build_scorer(person_level: 4, home_level: 2, all_levels: [ 1, 2, 3, 4 ],
        ratings: [ rated(4, "consistent") ])
      assert_in_delta(1.0 / 3, scorer.components[:prior], 0.001)
      assert_in_delta(1.0 / 3, scorer.performance_ratio, 0.001)
    end

    should "change nothing when the lens level is the home level" do
      with_home = build_scorer(person_level: 3, home_level: 3, all_levels: [ 1, 2, 3 ],
        ratings: [ rated(3, "consistent") ])
      without = build_scorer(person_level: 3, all_levels: [ 1, 2, 3 ], ratings: [ rated(3, "consistent") ])
      assert_in_delta(without.performance_ratio, with_home.performance_ratio, 0.001)
      assert_in_delta(1.0, with_home.components[:prior], 0.001)
    end

    should "assume below the lens level when the lens sits under home" do
      # Home E4, read as E2: only L1 is below both.
      scorer = build_scorer(person_level: 2, home_level: 4, all_levels: [ 1, 2, 3, 4 ],
        ratings: [ rated(2, "consistent") ])
      assert_in_delta(1.0, scorer.components[:prior], 0.001)
      assert_in_delta(1.0, scorer.components[:current], 0.001)
    end
  end

  # ── The scale ──

  context "the scale" do
    should "read 1.0 for consistent at the assessed level at EVERY level of the ladder" do
      [ 1, 3, 5, 7, 8 ].each do |level|
        scorer = build_scorer(person_level: level, all_levels: (1..8).to_a, ratings: [ rated(level, "consistent") ])
        assert_in_delta(1.0, scorer.performance_ratio, 0.001, "level #{level}")
      end
    end

    should "read 2.0 for the next level demonstrated in full, at every level" do
      [ 1, 3, 5, 7 ].each do |level|
        scorer = build_scorer(person_level: level, all_levels: (1..8).to_a,
          ratings: [ rated(level, "consistent"), rated(level + 1, "consistent") ])
        assert_in_delta(2.0, scorer.performance_ratio, 0.001, "level #{level}")
      end
    end

    should "read 1.5 for 'most of the time' at the next level, 1.25 for 'some'" do
      half = build_scorer(person_level: 3, all_levels: (1..8).to_a,
        ratings: [ rated(3, "consistent"), rated(4, "occasional") ])
      quarter = build_scorer(person_level: 3, all_levels: (1..8).to_a,
        ratings: [ rated(3, "consistent"), rated(4, "some") ])
      assert_in_delta(1.5, half.performance_ratio, 0.001)
      assert_in_delta(1.25, quarter.performance_ratio, 0.001)
    end

    should "read 1.5 when half the capabilities are consistent at the next level" do
      scorer = build_pair(person_level: 3, all_levels: [ 1, 2, 3, 4 ], ratings: [
        rated(3, "consistent"), rated(4, "consistent"),
        rated(3, "consistent", cap: CAP_B)
      ])
      assert_in_delta(1.5, scorer.performance_ratio, 0.001)
    end

    should "weight the next band by binding weight" do
      scorer = build_pair(person_level: 3, all_levels: [ 3, 4 ], weight_a: 2.0, weight_b: 1.0, ratings: [
        rated(3, "consistent"), rated(4, "consistent"),
        rated(3, "consistent", cap: CAP_B)
      ])
      # A carries 2/3 of the band and is consistent above → next = 0.667
      assert_in_delta(1.0 + 2.0 / 3.0, scorer.performance_ratio, 0.001)
    end

    should "weight the current band by binding weight" do
      scorer = build_pair(person_level: 1, all_levels: [ 1 ], weight_a: 2.0, weight_b: 1.0, ratings: [
        rated(1, "occasional"), rated(1, "consistent", cap: CAP_B)
      ])
      # (2 × 0.5 + 1 × 1.0) / 3
      assert_in_delta(2.0 / 3.0, scorer.performance_ratio, 0.001)
    end

    should "pin the score at 1.0 at the top of the ladder" do
      scorer = build_scorer(person_level: 8, all_levels: (1..8).to_a, ratings: [ rated(8, "consistent") ])
      assert_in_delta(1.0, scorer.performance_ratio, 0.001)
      assert_not scorer.has_next_level?
    end

    should "pool prior levels into one bucket rather than one per level" do
      # The prior bucket is ONE band's worth, averaged over every prior
      # level — so one "none" at L2 costs half of it with two prior levels
      # and a quarter with four (deliberate: the bucket, not the ladder,
      # is what the score is normalised over).
      at_three = build_scorer(person_level: 3, all_levels: [ 1, 2, 3 ],
        ratings: [ rated(2, "none"), rated(3, "consistent") ])
      at_five = build_scorer(person_level: 5, all_levels: [ 1, 2, 3, 4, 5 ],
        ratings: [ rated(2, "none"), rated(5, "consistent") ])
      assert_in_delta(0.5, at_three.performance_ratio, 0.001)
      assert_in_delta(0.75, at_five.performance_ratio, 0.001)
    end

    should "floor the score at zero" do
      scorer = build_scorer(person_level: 3, all_levels: [ 2, 3 ], ratings: [ rated(2, "none") ])
      assert_in_delta(0.0, scorer.performance_ratio, 0.001)
    end

    should "be unscorable (0.0) when no capability carries an expectation at the assessed level" do
      scorer = build_scorer(person_level: 3, all_levels: [ 1, 2, 3 ],
        expectation_cells: [ [ CAP_A, 1 ], [ CAP_A, 2 ] ])
      assert_in_delta(0.0, scorer.performance_ratio, 0.001)
    end

    should "expose the components the copy names" do
      scorer = build_scorer(person_level: 3, all_levels: [ 1, 2, 3, 4 ],
        ratings: [ rated(3, "consistent"), rated(4, "occasional") ])
      assert_equal({ prior: 1.0, current: 1.0, next: 0.5, score: 1.5, bands_above: 1 }, scorer.components)
    end

    should "score the assessed level identically to performance_ratio_at_level(person_level)" do
      scorer = build_pair(person_level: 3, all_levels: [ 1, 2, 3, 4 ], ratings: [
        rated(2, "some"), rated(3, "occasional"), rated(4, "consistent"),
        rated(3, "consistent", cap: CAP_B), rated(4, "some", cap: CAP_B)
      ])
      assert_in_delta(scorer.performance_ratio, scorer.performance_ratio_at_level(3), 0.0001)
    end
  end

  # ── The progression gate ──

  context "the progression gate" do
    should "discount a flexible capability's next-level credit by its current-level frequency" do
      scorer = build_scorer(person_level: 3, all_levels: [ 3, 4 ],
        ratings: [ rated(3, "occasional"), rated(4, "consistent") ])
      # 0.5 at L3 + 0.5 × 1.0 at L4
      assert_in_delta(0.5, scorer.components[:next], 0.001)
      assert_in_delta(1.0, scorer.performance_ratio, 0.001)
    end

    should "give a mandatory capability no next-level credit until it is consistent at its level" do
      scorer = build_scorer(person_level: 3, all_levels: [ 3, 4 ], deficit_threshold: 0,
        ratings: [ rated(3, "occasional"), rated(4, "consistent") ])
      assert_in_delta(0.0, scorer.components[:next], 0.001)
      assert_in_delta(0.5, scorer.performance_ratio, 0.001)
    end

    should "block a mandatory capability below the bar even when consistent above it" do
      # With a multiplicative gate this netted to zero and was never blocked.
      scorer = build_scorer(person_level: 3, all_levels: [ 3, 4 ], deficit_threshold: 0,
        ratings: [ rated(3, "occasional"), rated(4, "consistent") ])
      assert_equal :blocked, scorer.capability_statuses[CAP_A]
    end

    should "give an unrated current level no next-level credit at all" do
      scorer = build_scorer(person_level: 3, all_levels: [ 3, 4 ], ratings: [ rated(4, "consistent") ])
      assert_in_delta(0.0, scorer.performance_ratio, 0.001)
      assert_equal :unrated, scorer.capability_statuses[CAP_A]
    end

    should "chain the gate along the levels for a cap of 2" do
      consistent = build_scorer(person_level: 3, all_levels: [ 3, 4, 5 ], overperformance_cap: 2,
        ratings: [ rated(3, "consistent"), rated(4, "consistent"), rated(5, "consistent") ])
      gap_at_four = build_scorer(person_level: 3, all_levels: [ 3, 4, 5 ], overperformance_cap: 2,
        ratings: [ rated(3, "consistent"), rated(4, "none"), rated(5, "consistent") ])
      assert_in_delta(3.0, consistent.performance_ratio, 0.001)
      assert_in_delta(1.0, gap_at_four.performance_ratio, 0.001)
    end

    should "still allow making up across capabilities" do
      # A consistent at L3 and L4, B "most of the time" at L3: +1.0 − 0.5.
      scorer = build_pair(person_level: 3, all_levels: [ 3, 4 ], ratings: [
        rated(3, "consistent"), rated(4, "consistent"),
        rated(3, "occasional", cap: CAP_B)
      ])
      assert_in_delta(1.25, scorer.performance_ratio, 0.001)
      assert_equal :performing, scorer.performance_state
    end
  end

  # ── The ladder ──

  context "the ladder" do
    should "treat the next ORDINAL in the ladder as the next level, not person_level + 1" do
      # Levels [1, 2, 3, 5] — ordinal 4 was never authored.
      scorer = build_scorer(person_level: 3, all_levels: [ 1, 2, 3, 5 ],
        ratings: [ rated(3, "consistent"), rated(5, "consistent") ])
      assert_equal 5, scorer.next_level_ordinal
      assert scorer.has_next_level?
      assert_in_delta(2.0, scorer.performance_ratio, 0.001)
      assert scorer.promotion_readiness[:eligible]
    end

    should "not let a level with no expectation gate the credit above it" do
      # A senior-only capability: expectations start at L4. Rated consistent
      # there while assessed at L3, it earns its L4 credit in full.
      scorer = build_scorer(person_level: 3, all_levels: [ 3, 4 ],
        expectation_cells: [ [ CAP_A, 4 ] ], ratings: [ rated(4, "consistent") ])
      assert_in_delta(1.0, scorer.components[:next], 0.001)
    end

    should "report how many bands above can carry credit" do
      cap_two = build_scorer(person_level: 3, all_levels: [ 1, 2, 3, 4, 5 ], overperformance_cap: 2,
        ratings: [ rated(3, "consistent") ])
      near_top = build_scorer(person_level: 4, all_levels: [ 1, 2, 3, 4, 5 ], overperformance_cap: 2,
        ratings: [ rated(4, "consistent") ])
      assert_equal 2, cap_two.components[:bands_above]
      assert_equal 1, near_top.components[:bands_above]
    end
  end

  # ── Over-performance cap and expectation coverage ──

  context "cap and coverage" do
    should "ignore ratings beyond the cap window" do
      scorer = build_scorer(person_level: 3, all_levels: [ 3, 4, 5 ],
        ratings: [ rated(3, "consistent"), rated(5, "consistent") ])
      assert_in_delta(1.0, scorer.performance_ratio, 0.001)
      assert_equal :above_cap, scorer.capability_statuses[CAP_A]
    end

    should "pin the score at 1.0 with a cap of 0" do
      scorer = build_scorer(person_level: 3, all_levels: [ 3, 4 ], overperformance_cap: 0,
        ratings: [ rated(3, "consistent"), rated(4, "consistent") ])
      assert_in_delta(1.0, scorer.performance_ratio, 0.001)
    end

    should "normalise the next band over the capabilities that have an expectation there" do
      ratings = [ rated(3, "consistent"), rated(4, "consistent"), rated(3, "consistent", cap: CAP_B) ]
      cap_a = CapStub.new(stable_id: CAP_A, category_id: CAT_1)
      cap_b = CapStub.new(stable_id: CAP_B, category_id: CAT_1)
      bindings = [
        BindingStub.new(capability_id: "a", weight: 1.0, deficit_threshold: nil, overperformance_cap: nil, capability: cap_a),
        BindingStub.new(capability_id: "b", weight: 1.0, deficit_threshold: nil, overperformance_cap: nil, capability: cap_b)
      ]
      category = CategoryStub.new(category_id: CAT_1, deficit_threshold: nil, overperformance_cap: nil)
      build = ->(cells) do
        PersonDevelopment::Scoring.new(level_ratings: ratings, bindings: bindings, categories: [ category ],
          person_level: 3, all_level_ordinals: [ 3, 4 ], expectation_cells: cells)
      end

      # B has no expectation at L4 → the L4 band is A alone → 2.0
      assert_in_delta(2.0, build.call([ [ CAP_A, 3 ], [ CAP_A, 4 ], [ CAP_B, 3 ] ]).performance_ratio, 0.001)
      # nil = every cell exists → B owes its share of the L4 band → 1.5
      assert_in_delta(1.5, build.call(nil).performance_ratio, 0.001)
    end
  end

  # ── Category pass/fail ──

  context "#category_results" do
    should "pass when the category's own score clears the meeting bar" do
      scorer = build_scorer(person_level: 3, all_levels: [ 3 ], ratings: [ rated(3, "consistent") ],
        category_deficit_threshold: 0.5)
      result = scorer.category_results[CAT_1]
      assert result[:pass]
      assert_equal :top_of_ladder, result[:state]
      assert_in_delta(0.0, result[:pool], 0.01)
    end

    should "fail below the meeting bar even when the old points pool would have passed" do
      # "most of the time" → pool −0.5 (within the 0.75 tolerance) but 50% of the band
      scorer = build_scorer(person_level: 3, all_levels: [ 3 ], ratings: [ rated(3, "occasional") ])
      result = scorer.category_results[CAT_1]
      assert_not result[:pass]
      assert_equal :underperforming, result[:state]
    end

    should "fail when the score passes but a capability is blocked" do
      # cap_a "some" at L3 is blocked at category tolerance 0; cap_b consistent at L3 and L4.
      scorer = build_pair(person_level: 3, all_levels: [ 3, 4 ], category_deficit_threshold: 0, ratings: [
        rated(3, "some"),
        rated(3, "consistent", cap: CAP_B), rated(4, "consistent", cap: CAP_B)
      ])
      result = scorer.category_results[CAT_1]
      assert_not result[:pass]
      assert_equal :progressing, result[:state]
    end
  end

  # ── Altitudes ──

  context "#capability_components" do
    should "score one capability by the same formula as the assessment" do
      scorer = build_scorer(person_level: 3, all_levels: [ 1, 2, 3, 4 ],
        ratings: [ rated(3, "occasional"), rated(4, "consistent") ])
      components = scorer.capability_components(scorer.instance_variable_get(:@bindings).first)
      assert_in_delta(0.5, components[:current], 0.001)
      assert_in_delta(0.5, components[:next], 0.001)
      assert_in_delta(1.0, components[:score], 0.001)
      assert components[:scorable]
    end

    should "mark a capability with no expectation at the assessed level as not scorable" do
      scorer = build_scorer(person_level: 3, all_levels: [ 3, 4 ], expectation_cells: [ [ CAP_A, 4 ] ],
        ratings: [ rated(4, "consistent") ])
      assert_not scorer.capability_components(scorer.instance_variable_get(:@bindings).first)[:scorable]
    end
  end

  context "the bar's band count" do
    # The bar's scale is drawn from bands_above, so it must be the cap of
    # the bindings being scored — not the assessment's widest. A capability
    # capped at one level otherwise gets a 0–300 track it can never fill.
    should "follow each altitude's own cap, not the assessment's widest" do
      scorer = build_pair(
        person_level: 1, all_levels: [ 1, 2, 3 ], cap_a_limit: 1, cap_b_limit: 2,
        ratings: [ rated(1, "consistent"), rated(2, "consistent"), rated(3, "consistent"),
                   rated(1, "consistent", cap: CAP_B), rated(2, "consistent", cap: CAP_B),
                   rated(3, "consistent", cap: CAP_B) ]
      )
      bindings = scorer.instance_variable_get(:@bindings)

      assert_equal 2, scorer.components[:bands_above], "the assessment can reach both bands"
      assert_equal 1, scorer.capability_components(bindings.first)[:bands_above],
        "a capability capped at one level must not advertise a second band"
      assert_equal 2, scorer.capability_components(bindings.last)[:bands_above]
    end

    should "never claim more bands than the ladder has" do
      scorer = build_pair(person_level: 2, all_levels: [ 1, 2 ], cap_a_limit: 2, cap_b_limit: 2,
                          ratings: [ rated(2, "consistent") ])

      assert_equal 0, scorer.components[:bands_above]
    end
  end

  context "#capability_scores_at" do
    # The hero's gap list points at a level the person is not standing on,
    # so it needs each capability scored THERE — a share of that level's
    # expectation, not a weight-unit delta that reads the same for every
    # capability nobody has rated yet.
    should "score each capability as its share of the reference level" do
      scorer = build_pair(person_level: 3, all_levels: [ 3, 4 ], ratings: [
        rated(3, "consistent"), rated(4, "some"),
        rated(3, "consistent", cap: CAP_B)
      ])
      scores = scorer.capability_scores_at(4)

      # "Some of the time" at E4 is a quarter of it; never rated there is none.
      assert_in_delta(0.25, scores[CAP_A][:score], 0.001)
      assert_in_delta(0.0, scores[CAP_B][:score], 0.001)
    end

    should "distinguish capabilities a weight-unit delta rated identically" do
      scorer = build_pair(person_level: 3, all_levels: [ 3, 4 ], ratings: [
        rated(3, "consistent"), rated(4, "occasional"),
        rated(3, "consistent", cap: CAP_B)
      ])
      scores = scorer.capability_scores_at(4)

      assert_operator scores[CAP_A][:score], :>, scores[CAP_B][:score],
        "a capability shown at the next level must outrank one never shown there"
    end

    should "mark a capability with no expectation at that level unscorable" do
      scorer = build_scorer(person_level: 3, all_levels: [ 3, 4 ],
                            expectation_cells: Set[[ CAP_A, 3 ]],
                            ratings: [ rated(3, "consistent") ])
      score = scorer.capability_scores_at(4)[CAP_A]

      assert_equal false, score[:scorable],
        "nothing is expected of it at that level, so it owes nothing there"
    end

    should "read the top of the ladder from the level being judged" do
      # The reference level here IS the last on the ladder, so a capability
      # meeting it is at the top — whatever levels sit above the one the
      # person is standing on.
      scorer = build_pair(person_level: 3, all_levels: [ 3, 4 ], ratings: [
        rated(3, "consistent"), rated(4, "consistent"),
        rated(3, "consistent", cap: CAP_B)
      ])

      assert_equal :top_of_ladder, scorer.capability_scores_at(4)[CAP_A][:state]
    end

    should "carry the state vocabulary at that level" do
      scorer = build_pair(person_level: 3, all_levels: [ 3, 4 ], ratings: [
        rated(3, "consistent"), rated(4, "consistent"),
        rated(3, "consistent", cap: CAP_B)
      ])
      scores = scorer.capability_scores_at(4)

      assert_equal :underperforming, scores[CAP_B][:state]
      assert_includes %i[performing mastering top_of_ladder], scores[CAP_A][:state]
    end
  end

  context "#category_components and #category_state" do
    should "be the weight-mean of the category's capabilities" do
      scorer = build_pair(person_level: 3, all_levels: [ 3, 4 ], ratings: [
        rated(3, "consistent"), rated(4, "consistent"),
        rated(3, "occasional", cap: CAP_B)
      ])
      assert_in_delta(1.25, scorer.category_components(CAT_1)[:score], 0.001)
      assert_in_delta(1.25, scorer.performance_ratio, 0.001)
      assert_equal :performing, scorer.category_state(CAT_1)
    end

    should "read mastering, eligible and top of ladder by the same rules as the assessment" do
      mastering = build_pair(person_level: 3, all_levels: [ 3, 4 ], ratings: [
        rated(3, "consistent"), rated(4, "consistent"),
        rated(3, "consistent", cap: CAP_B), rated(4, "some", cap: CAP_B)
      ])
      eligible = build_pair(person_level: 3, all_levels: [ 3, 4 ], ratings: [
        rated(3, "consistent"), rated(4, "consistent"),
        rated(3, "consistent", cap: CAP_B), rated(4, "consistent", cap: CAP_B)
      ])
      top = build_pair(person_level: 3, all_levels: [ 3 ], ratings: [
        rated(3, "consistent"), rated(3, "consistent", cap: CAP_B)
      ])
      assert_equal :mastering, mastering.category_state(CAT_1)
      assert_equal :eligible, eligible.category_state(CAT_1)
      assert_equal :top_of_ladder, top.category_state(CAT_1)
    end

    should "downgrade a category to progressing when a member is blocked" do
      scorer = build_pair(person_level: 3, all_levels: [ 3, 4 ], ratings: [
        rated(3, "consistent"), rated(4, "consistent"),
        rated(3, "none", cap: CAP_B)
      ])
      assert_in_delta(1.0, scorer.category_components(CAT_1)[:score], 0.001)
      assert_equal :progressing, scorer.category_state(CAT_1)
    end
  end

  # ── Verdicts ──

  context "#meeting_expectations?" do
    should "return true when rated consistent at the assessed level" do
      scorer = build_scorer(person_level: 3, all_levels: [ 3 ], ratings: [ rated(3, "consistent") ])
      assert scorer.meeting_expectations?
    end

    should "return false below the meeting threshold" do
      scorer = build_scorer(person_level: 3, all_levels: [ 3 ], ratings: [ rated(3, "occasional") ])
      assert_not scorer.meeting_expectations?
    end
  end

  context "#mastering?" do
    should "default to the halfway waypoint (1.5)" do
      half = build_scorer(person_level: 3, all_levels: [ 3, 4 ],
        ratings: [ rated(3, "consistent"), rated(4, "occasional") ])
      quarter = build_scorer(person_level: 3, all_levels: [ 3, 4 ],
        ratings: [ rated(3, "consistent"), rated(4, "some") ])
      assert half.mastering?
      assert_not quarter.mastering?
    end

    should "honour an explicit mastery threshold" do
      scorer = build_scorer(person_level: 3, all_levels: [ 3 ], ratings: [ rated(3, "consistent") ],
        thresholds: { mastery_threshold: 0.8 })
      assert scorer.mastering?
    end

    should "never be true for a person with a blocked capability" do
      scorer = build_pair(person_level: 3, all_levels: [ 2, 3, 4 ], tolerance_b: 0, ratings: [
        rated(3, "consistent"), rated(4, "consistent"),
        rated(3, "occasional", cap: CAP_B), rated(4, "consistent", cap: CAP_B)
      ])
      # 1.0 + 0.5 current, next = (1.0 + 0) / 2 → 1.25; B blocked
      assert_not scorer.mastering?
      assert_equal :blocked, scorer.capability_statuses[CAP_B]
    end
  end

  # ── Performance state ──

  # A single-capability scorer at L3 with a next level available.
  def scorer_with_current(frequency, next_frequency: nil, **kwargs)
    ratings = [ rated(3, frequency) ]
    ratings << rated(4, next_frequency) if next_frequency
    build_scorer(person_level: 3, all_levels: [ 1, 2, 3, 4 ], ratings: ratings, **kwargs)
  end

  context "#performance_state" do
    should "return :underperforming just below underperforming_threshold" do
      scorer = scorer_with_current("occasional", thresholds: { underperforming_threshold: 0.51 })
      assert_equal :underperforming, scorer.performance_state
    end

    should "return :progressing exactly at underperforming_threshold" do
      scorer = scorer_with_current("occasional", thresholds: { underperforming_threshold: 0.5 })
      assert_equal :progressing, scorer.performance_state
    end

    should "return :underperforming for 'most of the time' at the default 0.80 threshold" do
      assert_equal :underperforming, scorer_with_current("occasional").performance_state
    end

    should "return :progressing just below meeting_expectation_threshold" do
      scorer = scorer_with_current("occasional",
        thresholds: { underperforming_threshold: 0.4, meeting_expectation_threshold: 0.6 })
      assert_equal :progressing, scorer.performance_state
    end

    should "return :performing exactly at meeting_expectation_threshold" do
      scorer = scorer_with_current("occasional",
        thresholds: { underperforming_threshold: 0.4, meeting_expectation_threshold: 0.5, mastery_threshold: 0.6 })
      assert_equal :performing, scorer.performance_state
    end

    should "return :performing below the mastery waypoint" do
      assert_equal :performing, scorer_with_current("consistent", next_frequency: "some").performance_state
    end

    should "return :mastering at the mastery waypoint when not yet eligible" do
      scorer = scorer_with_current("consistent", next_frequency: "occasional")
      assert_in_delta(1.5, scorer.performance_ratio, 0.001)
      assert_equal :mastering, scorer.performance_state
      assert_not scorer.promotion_readiness[:eligible]
    end

    should "return :eligible when next-level expectations are met (precedence over mastering)" do
      scorer = scorer_with_current("consistent", next_frequency: "consistent")
      assert_equal :eligible, scorer.performance_state
    end

    should "downgrade a meeting score to :progressing when any capability is blocked" do
      # A consistent at L3 and L4 lifts the score to 1.0; B "not yet" at L3 is blocked.
      scorer = build_pair(person_level: 3, all_levels: [ 3, 4 ], ratings: [
        rated(3, "consistent"), rated(4, "consistent"),
        rated(3, "none", cap: CAP_B)
      ])
      assert_in_delta(1.0, scorer.performance_ratio, 0.001)
      assert_equal :progressing, scorer.performance_state
    end

    should "return :top_of_ladder when meeting at the highest level" do
      scorer = build_scorer(person_level: 3, all_levels: [ 1, 2, 3 ], ratings: [ rated(3, "consistent") ])
      assert_equal :top_of_ladder, scorer.performance_state
      assert_not scorer.has_next_level?
    end

    should "still report the current-level bar at the top of the ladder" do
      scorer = build_scorer(person_level: 3, all_levels: [ 1, 2, 3 ], ratings: [ rated(3, "occasional") ])
      assert_equal :underperforming, scorer.performance_state
    end
  end

  context "#has_next_level? and #next_level_contribution" do
    should "return true and a next-level contribution when not at the top" do
      scorer = build_scorer(person_level: 3, all_levels: [ 1, 2, 3, 4 ], ratings: [ rated(3, "consistent") ])
      assert scorer.has_next_level?
      binding_obj = scorer.instance_variable_get(:@bindings).first
      # At L4: L1–L3 contribute 0, L4 unrated → −1.0
      assert_in_delta(-1.0, scorer.next_level_contribution(binding_obj), 0.01)
    end

    should "return false at the top of the level ladder" do
      scorer = build_scorer(person_level: 4, all_levels: [ 1, 2, 3, 4 ])
      assert_not scorer.has_next_level?
    end
  end

  # ── Agreed level ──

  context "#agreed_level_for" do
    should "return the highest level_ordinal where effective_frequency is consistent" do
      scorer = build_scorer(person_level: 3, all_levels: [ 1, 2, 3, 4 ],
        ratings: [ rated(3, "consistent"), rated(4, "occasional") ])
      assert_equal 3, scorer.agreed_level_for(CAP_A)
    end

    should "return nil when no level has consistent effective_frequency" do
      scorer = build_scorer(person_level: 2, all_levels: [ 3 ], ratings: [ rated(3, "some") ])
      assert_nil scorer.agreed_level_for(CAP_A)
    end
  end

  # ── Level scoring (one formula for every reference level) ──

  context "#performance_ratio_at_level" do
    should "score identically for unrated and explicitly consistent at levels below current" do
      scorer_unrated = build_scorer(person_level: 3, all_levels: [ 1 ], ratings: [])
      scorer_rated = build_scorer(person_level: 3, all_levels: [ 1 ], ratings: [ rated(1, "consistent") ])

      assert_in_delta(
        scorer_rated.performance_ratio_at_level(1),
        scorer_unrated.performance_ratio_at_level(1),
        0.001,
        "Unrated below current level should score the same as explicitly consistent"
      )
    end

    should "treat the assessed level as a prior level when scoring the next one" do
      scorer = build_scorer(person_level: 3, all_levels: [ 3, 4 ],
        ratings: [ rated(3, "occasional"), rated(4, "consistent") ])
      # At L4: prior = 0.5 (L3), current = 1.0 → 0.5
      assert_in_delta(0.5, scorer.performance_ratio_at_level(4), 0.001)
    end
  end

  # ── Level verdict (unified column header + promotion code path) ──

  context "#level_verdict" do
    should "return :meeting when the score meets threshold and no blocked capabilities" do
      scorer = build_scorer(person_level: 3, all_levels: [ 3 ], ratings: [ rated(3, "consistent") ])
      assert_equal :meeting, scorer.level_verdict(3)
    end

    should "return :mastering when the score meets the mastery threshold" do
      scorer = build_scorer(person_level: 3, all_levels: [ 1, 2, 3, 4 ],
        ratings: [ rated(3, "consistent"), rated(4, "consistent") ])
      assert_equal :mastering, scorer.level_verdict(3)
    end

    should "return :below when the score meets threshold but a capability is blocked" do
      # A mandatory capability (tolerance 0, weight 0.5) unrated at L3 blocks;
      # B (weight 1.5) consistent lifts the score to 0.75 ≥ a 0.7 threshold.
      scorer = build_pair(person_level: 3, all_levels: [ 3 ], tolerance_a: 0.0,
        weight_a: 0.5, weight_b: 1.5, thresholds: { meeting_expectation_threshold: 0.7 },
        ratings: [ rated(3, "consistent", cap: CAP_B) ])
      assert_in_delta(0.75, scorer.performance_ratio, 0.001)
      assert_equal :below, scorer.level_verdict(3)
    end

    should "agree with the hero's verdict at the assessed level" do
      scorer = build_scorer(person_level: 3, all_levels: [ 1, 2, 3, 4 ],
        ratings: [ rated(3, "consistent"), rated(4, "occasional") ])
      assert scorer.mastering?
      assert_equal :mastering, scorer.level_verdict(3)
    end
  end

  # ── Promotion readiness ──

  context "#promotion_readiness" do
    should "hold the next level when a Required capability is consistent there but unrated at the current level" do
      scorer = build_scorer(person_level: 3, all_levels: [ 1, 2, 3, 4 ], deficit_threshold: 0.0,
        ratings: [ rated(4, "consistent") ], thresholds: { meeting_expectation_threshold: 0.7 })
      result = scorer.promotion_readiness
      assert_not result[:eligible]
      assert_empty result[:blocked_at_next_level]
      assert_equal [ CAP_A ], result[:unrated_required_at_next_level]
    end

    should "be eligible when consistent at both the current and next level" do
      scorer = build_scorer(person_level: 3, all_levels: [ 1, 2, 3, 4 ], deficit_threshold: 0.0,
        ratings: [ rated(3, "consistent"), rated(4, "consistent") ])
      result = scorer.promotion_readiness
      assert result[:eligible]
      assert_empty result[:blocked_at_next_level]
      assert_empty result[:unrated_required_at_next_level]
    end

    should "require the same share of the next band at every level" do
      [ 1, 3, 5, 7 ].each do |level|
        scorer = build_scorer(person_level: level, all_levels: (1..8).to_a,
          ratings: [ rated(level, "consistent"), rated(level + 1, "occasional") ])
        assert_not scorer.promotion_readiness[:eligible], "level #{level}"
        assert_in_delta(0.5, scorer.performance_ratio_at_level(level + 1), 0.001, "level #{level}")
      end
    end

    should "not be eligible when a mandatory capability is not rated at the next level" do
      scorer = build_scorer(person_level: 3, all_levels: [ 1, 2, 3, 4 ], deficit_threshold: 0.0,
        ratings: [ rated(3, "consistent") ])
      result = scorer.promotion_readiness
      assert_not result[:eligible]
      assert_empty result[:blocked_at_next_level]
      assert_equal [ CAP_A ], result[:unrated_required_at_next_level]
    end

    should "block a flexible capability whose rated deficit at the next level exceeds the tolerance" do
      # "Not yet" at L3 and L4: −1.0 −1.0 at L4 → deficit 2.0 > 0.75.
      scorer = build_scorer(person_level: 3, all_levels: [ 1, 2, 3, 4 ],
        ratings: [ rated(3, "none"), rated(4, "none") ])
      assert_includes scorer.promotion_readiness[:blocked_at_next_level], CAP_A
    end

    should "neither block nor hold a flexible capability nobody has rated at the next level" do
      scorer = build_scorer(person_level: 3, all_levels: [ 1, 2, 3, 4 ], ratings: [])
      result = scorer.promotion_readiness
      assert_not result[:eligible], "an unrated level still scores 0, so it can't be met"
      assert_empty result[:blocked_at_next_level]
      assert_empty result[:unrated_required_at_next_level]
    end

    should "not block a flexible capability whose deficit at the next level is within the tolerance" do
      # Consistent at L3, "most of the time" at L4 → deficit 0.5 ≤ 0.75.
      scorer = build_scorer(person_level: 3, all_levels: [ 1, 2, 3, 4 ],
        ratings: [ rated(3, "consistent"), rated(4, "occasional") ])
      assert_empty scorer.promotion_readiness[:blocked_at_next_level]
    end
  end

  # ── Block reasons ──

  context "block_reasons" do
    should "return empty hash when no capabilities are blocked" do
      scorer = build_scorer(person_level: 3, all_levels: [ 3 ], ratings: [ rated(3, "consistent") ])
      assert_empty scorer.block_reasons
    end

    should "return reason for a blocked capability" do
      scorer = build_scorer(person_level: 3, all_levels: [ 3 ], ratings: [ rated(3, "some") ],
        deficit_threshold: 0)
      reasons = scorer.block_reasons
      assert_includes reasons.keys, CAP_A
      assert_includes reasons[CAP_A], "Below expectations by 0.8 points"
      assert_includes reasons[CAP_A], "no deficit allowed"
    end

    should "return reason with max allowed when threshold is non-zero" do
      scorer = build_scorer(person_level: 3, all_levels: [ 3 ], ratings: [ rated(3, "none") ],
        weight: 2.0, deficit_threshold: 1.0)
      reasons = scorer.block_reasons
      assert_includes reasons[CAP_A], "Below expectations by 2.0 points"
      assert_includes reasons[CAP_A], "max allowed: 1.0"
    end

    should "let a flexible capability's gated next-level credit close its own gap" do
      # "most of the time" at L3 (−0.5) + 0.5 × consistent at L4 (+0.5) → no deficit.
      scorer = build_scorer(person_level: 3, all_levels: [ 3, 4 ],
        ratings: [ rated(3, "occasional"), rated(4, "consistent") ])
      assert_empty scorer.block_reasons
      assert_not_equal :blocked, scorer.capability_statuses[CAP_A]
    end

    should "not include non-blocked capabilities" do
      scorer = build_pair(person_level: 3, all_levels: [ 3 ], tolerance_a: 0, tolerance_b: 0, ratings: [
        rated(3, "some"), rated(3, "consistent", cap: CAP_B)
      ])
      reasons = scorer.block_reasons
      assert_includes reasons.keys, CAP_A
      assert_not_includes reasons.keys, CAP_B
    end
  end

  # ── Only a rating can block ──

  context "an unrated capability" do
    should "not be blocked, though the score still counts it as 0" do
      scorer = build_scorer(person_level: 3, all_levels: [ 1, 2, 3, 4 ], ratings: [])
      assert_equal :unrated, scorer.capability_statuses[CAP_A]
      assert_empty scorer.block_reasons
      assert_in_delta(0.0, scorer.performance_ratio, 0.001)
    end

    should "still be blocked by a \"not yet\" rating" do
      scorer = build_scorer(person_level: 3, all_levels: [ 1, 2, 3, 4 ], ratings: [ rated(3, "none") ])
      assert_equal :blocked, scorer.capability_statuses[CAP_A]
      assert_includes scorer.block_reasons[CAP_A], "Below expectations by 1.0 points"
    end

    should "still be blocked by a \"not yet\" below the assessed level while the assessed level is unrated" do
      scorer = build_scorer(person_level: 3, all_levels: [ 1, 2, 3, 4 ], ratings: [ rated(2, "none") ])
      assert_equal :blocked, scorer.capability_statuses[CAP_A]
      assert_includes scorer.block_reasons[CAP_A], "Below expectations by 1.0 points"
    end

    should "not hold the state when it is flexible" do
      scorer = build_pair(person_level: 3, all_levels: [ 1, 2, 3, 4 ],
        thresholds: { meeting_expectation_threshold: 0.5, underperforming_threshold: 0.4 },
        ratings: [ rated(3, "consistent") ])
      assert_equal :unrated, scorer.capability_statuses[CAP_B]
      assert scorer.meeting_expectations?
      assert_equal :performing, scorer.performance_state
      assert scorer.category_results[CAT_1][:pass]
    end

    should "hold the state at progressing when it is Required" do
      scorer = build_pair(person_level: 3, all_levels: [ 1, 2, 3, 4 ], tolerance_b: 0,
        thresholds: { meeting_expectation_threshold: 0.5, underperforming_threshold: 0.4 },
        ratings: [ rated(3, "consistent") ])
      assert_equal :unrated, scorer.capability_statuses[CAP_B]
      assert_empty scorer.block_reasons
      assert_equal [ CAP_B ], scorer.unrated_required
      assert_not scorer.meeting_expectations?
      assert_equal :progressing, scorer.performance_state
      assert_equal :progressing, scorer.category_results[CAT_1][:state]
    end

    should "stop counting once it is rated" do
      scorer = build_pair(person_level: 3, all_levels: [ 1, 2, 3, 4 ], tolerance_b: 0,
        ratings: [ rated(3, "consistent"), rated(3, "consistent", cap: CAP_B) ])
      assert_empty scorer.unrated_required
      assert_equal :at_bar, scorer.capability_statuses[CAP_B]
    end

    should "read the viewer's perspective, so a manager rating doesn't fill an unrated self cell" do
      manager_only = Rating.new(capability_stable_id: CAP_A, level_ordinal: 3,
        aligned_frequency: nil, manager_rated_frequency: "none", self_rated_frequency: nil)
      cap = CapStub.new(stable_id: CAP_A, category_id: CAT_1)
      self_view = PersonDevelopment::Scoring.new(
        level_ratings: [ manager_only ],
        bindings: [ BindingStub.new(capability_id: "bid", weight: 1.0, capability: cap) ],
        categories: [ CategoryStub.new(category_id: CAT_1) ],
        person_level: 3, all_level_ordinals: [ 3 ], expectation_cells: nil, perspective: :self_only
      )
      assert_equal :unrated, self_view.capability_statuses[CAP_A]
    end

    should "be unrated, not blocked, at a lens level above the home level" do
      # E2 read as E4: L3 and L4 are no longer assumed, and nobody rated them.
      scorer = build_scorer(person_level: 4, home_level: 2, all_levels: [ 1, 2, 3, 4 ],
        ratings: [ rated(2, "consistent") ])
      assert_equal :unrated, scorer.capability_statuses[CAP_A]
    end
  end
end
