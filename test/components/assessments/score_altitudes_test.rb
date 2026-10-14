# frozen_string_literal: true

require "test_helper"

# One scale at every altitude (ADR-21, #413): the capability name row and
# the category indicators read the same components, the same tone rules
# and the same bar as the hero. Rendered directly from scoring hashes so
# each state is pinned without a browser fixture.
class Views::Assessments::ScoreAltitudesTest < ActiveSupport::TestCase
  CAP = Struct.new(:stable_id, :name, keyword_init: true)
  CATEGORY = Struct.new(:category_id, :name, keyword_init: true)

  LEVELS = [
    { ordinal: 2, level_code: "E2" }, { ordinal: 3, level_code: "E3" }, { ordinal: 4, level_code: "E4" }
  ].freeze
  SCORE = { prior: 1.0, current: 0.5, next: 0.5, score: 1.0, bands_above: 1,
            scorable: true, state: :performing }.freeze

  def name_row(score:, rated: true, blocked: false, to_confirm: false)
    Views::Assessments::CapabilityNameRow.new(
      capability: CAP.new(stable_id: "cap-a", name: "Strategic Thinking"),
      score: score, rated: rated, blocked: blocked, block_reason: blocked ? "Below expectations by 1.0 points" : nil,
      merged_levels: LEVELS, person_level: 3, to_confirm: to_confirm
    ).call
  end

  def indicators(score:, rated: 2, total: 2, secondary: [], manager_rated: nil, context: :self)
    manager_rated = rated if manager_rated.nil?
    capabilities = Array.new(total) do |i|
      { cells: { 3 => { current_frequency: i < rated ? "consistent" : nil,
                        manager_frequency: i < manager_rated ? "consistent" : nil } } }
    end
    Views::Assessments::CategoryIndicators.new(
      category_id: "cat-1", category_score: score, secondary_scores: secondary,
      category_data: { person_level: 3, capabilities: capabilities },
      context: context, merged_levels: LEVELS, person_level: 3
    ).call
  end

  def chip_bar(score:, rated: 1, total: 1)
    capabilities = Array.new(total) { |i| { cells: { 3 => { current_frequency: i < rated ? "consistent" : nil } } } }
    Views::Assessments::CategoryChipBar.new(
      categories: [ { category: CATEGORY.new(category_id: "cat-1", name: "Thinking"),
                      person_level: 3, capabilities: capabilities } ],
      scoring: { category_scores: { "cat-1" => score } },
      context: :self
    ).call
  end

  context "CapabilityNameRow" do
    # #480: a dashed outline on the pill was the only sign a value was carried.
    should "say To confirm when the assessed-level value was carried and still asks" do
      assert_includes name_row(score: SCORE, to_confirm: true), "To confirm"
      assert_not_includes name_row(score: SCORE), "To confirm"
    end

    should "show a weight chip only when the capability's weight is not 1" do
      weighted = name_row(score: SCORE.merge(weight: 2.0))
      assert_includes weighted, "×2"
      assert_includes weighted, 'id="assessment-term-weight-cap-a"'
      assert_includes weighted, "twice as much"

      half = name_row(score: SCORE.merge(weight: 0.5))
      assert_includes half, "×0.5"
      assert_includes half, "half as much"

      plain = name_row(score: SCORE.merge(weight: 1.0))
      assert_not_includes plain, "×1"
      assert_not_includes plain, "assessment-term-weight"
    end

    should "show Required before any rating, independent of Blocked" do
      required = name_row(score: SCORE.merge(required: true), rated: false)
      assert_includes required, "Required"
      assert_includes required, 'id="assessment-term-required-cap-a"'
      assert_not_includes required, "assessment-term-blocked"

      assert_not_includes name_row(score: SCORE), "assessment-term-required"
    end

    should "keep the chips grey rather than coloured by state" do
      html = name_row(score: SCORE.merge(weight: 2.0, required: true))
      chip = html[/<button[^>]*aria-describedby="assessment-term-weight-cap-a"[^>]*>/]
      assert chip, "expected the weight chip trigger"
      assert_includes chip, "text-gray-700"
      assert_not_includes chip, "text-green-700"
    end

    should "show the score with its split, never the net alone" do
      html = name_row(score: SCORE)
      assert_includes html, "100%"
      assert_includes html, "50% · +50% toward E4"
      assert_includes html, "text-green-700"
      assert_includes html, 'role="progressbar"'
      assert_includes html, 'aria-valuemax="200"'
    end

    should "read Not rated instead of 0% before the assessed level is rated" do
      html = name_row(rated: false, score: { prior: 1.0, current: 0.0, next: 0.0, score: 0.0, bands_above: 1,
                                             scorable: true, state: :underperforming })
      assert_includes html, "Not rated"
      assert_not_includes html, "0%"
    end

    should "say when the capability has no expectation at the assessed level" do
      html = name_row(score: { prior: 1.0, current: 0.0, next: 1.0, score: 0.0, bands_above: 1,
                               scorable: false, state: :underperforming })
      assert_includes html, "No expectation at E3"
    end

    should "colour a blocked capability like its badge" do
      html = name_row(blocked: true, score: { prior: 1.0, current: 0.0, next: 0.0, score: 0.0, bands_above: 1,
                                              scorable: true, state: :progressing })
      assert_includes html, "Blocked"
      assert_includes html, "text-amber-700"
    end
  end

  context "CategoryIndicators" do
    should "show the category's score, state word and bar once unlocked" do
      html = indicators(score: { prior: 1.0, current: 1.0, next: 0.5, score: 1.5, bands_above: 1,
                                 scorable: true, state: :mastering })
      assert_includes html, "150%"
      assert_includes html, 'title="Mastering"'
      assert_not_includes html, ">Mastering<"
      assert_includes html, "100% · +50% toward E4"
      assert_includes html, "text-purple-600"
      assert_includes html, "2/2 rated"
    end

    should "hold the score behind the coverage gate" do
      html = indicators(rated: 1, total: 4, score: { prior: 1.0, current: 0.25, next: 0.0, score: 0.25,
                                                    bands_above: 1, scorable: true, state: :underperforming })
      assert_includes html, "1/4 rated"
      assert_includes html, "score unlocks at 2"
      assert_not_includes html, "25%"
    end

    should "annotate a divergent secondary perspective on the same scale" do
      html = indicators(
        score: { prior: 1.0, current: 1.0, next: 0.0, score: 1.0, bands_above: 1, scorable: true, state: :performing },
        secondary: [ { label: "Self", context: :self,
                       score: { prior: 1.0, current: 0.45, next: 0.0, score: 0.45, bands_above: 1,
                                scorable: true, state: :underperforming } } ]
      )
      assert_includes html, "Self:"
      assert_includes html, "45%"
      assert_includes html, 'title="Underperforming"'
    end

    should "withhold a secondary perspective that has not rated enough to be scored" do
      # A manager who has rated every cell must not read "Self: 0%" as a
      # verdict when the assessee simply has not started.
      html = indicators(
        context: :manager, rated: 0, total: 4, manager_rated: 4,
        score: { prior: 1.0, current: 1.0, next: 0.0, score: 1.0, bands_above: 1,
                 scorable: true, state: :performing },
        secondary: [ { label: "Self", context: :self,
                       score: { prior: 1.0, current: 0.0, next: 0.0, score: 0.0, bands_above: 1,
                                scorable: true, state: :underperforming } } ]
      )

      # The primary must be scored here, or the assertion would pass
      # simply because the whole cluster is gated.
      assert_includes html, "100%"
      assert_not_includes html, "Self:"
      # No annotation at all — the amber divergence dot is the row's marker.
      assert_not_includes html, "bg-amber-400"
    end

    should "read as meeting at the top of the ladder" do
      html = Views::Assessments::CategoryIndicators.new(
        category_id: "cat-1",
        category_score: { prior: 1.0, current: 1.0, next: 0.0, score: 1.0, bands_above: 0, scorable: true, state: :top_of_ladder },
        category_data: { person_level: 4, capabilities: [ { cells: { 4 => { current_frequency: "consistent" } } } ] },
        context: :self, merged_levels: LEVELS, person_level: 4
      ).call
      assert_includes html, 'title="Meeting"'
      assert_includes html, 'aria-valuemax="100"'
    end
  end

  context "CategoryChipBar" do
    should "carry the state dot and the percent once the category is scored" do
      html = chip_bar(score: { prior: 1.0, current: 1.0, next: 0.0, score: 1.0,
                               bands_above: 1, scorable: true, state: :performing })

      assert_includes html, "data-category-status"
      assert_includes html, "100%"
    end

    should "hold both back behind the coverage gate, like the section header" do
      html = chip_bar(rated: 1, total: 4,
                      score: { prior: 1.0, current: 0.25, next: 0.0, score: 0.25,
                               bands_above: 1, scorable: true, state: :underperforming })

      assert_not_includes html, "data-category-status"
      assert_not_includes html, "25%"
    end

    should "show no score for a category with no expectation at the assessed level" do
      # The section header reads "no score"; a red 0% dot on the chip for
      # the same category is the worse of the two lies.
      html = chip_bar(score: { prior: 1.0, current: 0.0, next: 0.0, score: 0.0,
                               bands_above: 1, scorable: false, state: :underperforming })

      assert_not_includes html, "data-category-status"
      assert_not_includes html, "0%"
      assert_includes html, "Thinking"
    end
  end

  context "defined terms" do
    # The ⓘ glyph wrapped onto its own line under the term in a compact
    # category header, because a custom trigger class dropped the flex
    # layout the Kit default carries.
    should "keep the glyph on the term's own line" do
      html = indicators(rated: 1, total: 4,
                        score: { prior: 1.0, current: 0.25, next: 0.0, score: 0.25,
                                 bands_above: 1, scorable: true, state: :underperforming })

      assert_includes html, "inline-flex items-center min-h-6"
    end

    should "stay reachable as a real control at the AA tap-target floor" do
      html = indicators(rated: 1, total: 4,
                        score: { prior: 1.0, current: 0.25, next: 0.0, score: 0.25,
                                 bands_above: 1, scorable: true, state: :underperforming })

      assert_includes html, "min-h-6"
      assert_includes html, 'aria-describedby="assessment-term-rated-count-cat-1"'
    end
  end

  context "ScoreBar" do
    should "label the ticks only at hero size" do
      base = { score: 1.4, state: :performing, components: { bands_above: 1 }, merged_levels: LEVELS, person_level: 3 }
      lg = Views::Assessments::ScoreBar.new(**base, size: :lg).call
      sm = Views::Assessments::ScoreBar.new(**base, size: :sm).call
      assert_includes lg, "200% · E4"
      assert_not_includes sm, "200% · E4"
      assert_includes sm, 'aria-valuenow="140"'
    end
  end
end
