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

  def name_row(score:, rated: true, blocked: false)
    Views::Assessments::CapabilityNameRow.new(
      capability: CAP.new(stable_id: "cap-a", name: "Strategic Thinking"),
      score: score, rated: rated, blocked: blocked, block_reason: blocked ? "Below expectations by 1.0 points" : nil,
      merged_levels: LEVELS, person_level: 3
    ).call
  end

  def indicators(score:, rated: 2, total: 2, secondary: [])
    cells = { 3 => { current_frequency: "consistent" } }
    capabilities = Array.new(total) { |i| { cells: { 3 => { current_frequency: i < rated ? "consistent" : nil } } } }
    Views::Assessments::CategoryIndicators.new(
      category_id: "cat-1", category_score: score, secondary_scores: secondary,
      category_data: { person_level: 3, capabilities: capabilities },
      context: :self, merged_levels: LEVELS, person_level: 3
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
    should "show the score with its split, never the net alone" do
      html = name_row(score: { prior: 1.0, current: 0.5, next: 0.5, score: 1.0, bands_above: 1,
                               scorable: true, state: :performing })
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
        secondary: [ [ "Self", { prior: 1.0, current: 0.45, next: 0.0, score: 0.45, bands_above: 1,
                                 scorable: true, state: :underperforming } ] ]
      )
      assert_includes html, "Self:"
      assert_includes html, "45%"
      assert_includes html, 'title="Underperforming"'
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
