# frozen_string_literal: true

require "test_helper"

# The hero's copy on the level-independent scale (ADR-21): the verdict follows
# `performance_state`, the gloss names the score's parts, and the bar is
# labelled with the level codes. Rendered directly from a scoring hash so the
# states a browser fixture can't easily reach (top of the ladder, a blocked
# capability at a meeting score) are pinned too.
class Views::Assessments::HeroSummaryTest < ActiveSupport::TestCase
  CAP = Struct.new(:stable_id, :name, keyword_init: true)

  LEVELS = [
    { ordinal: 1, level_code: "E1" }, { ordinal: 2, level_code: "E2" },
    { ordinal: 3, level_code: "E3" }, { ordinal: 4, level_code: "E4" }
  ].freeze

  def render_hero(state:, components:, person_level: 3, levels: LEVELS, statuses: {}, readiness: nil,
                  contributions: { "cap-a" => 0.0 }, next_contributions: { "cap-a" => -0.5 }, context: :self)
    cap = CAP.new(stable_id: "cap-a", name: "Strategic Thinking")
    categories = [ {
      category: nil,
      capabilities: [ { capability: cap, cells: { person_level => {
        current_frequency: "consistent", manager_frequency: "consistent", aligned_frequency: "consistent"
      } } } ]
    } ]
    scoring = {
      performance_ratio: components[:score],
      components: components,
      performance_state: state,
      top_of_ladder: levels.none? { |l| l[:ordinal] > person_level },
      meeting_expectations: components[:score] >= 0.95,
      mastering: components[:score] >= 1.5,
      capability_statuses: statuses,
      capability_contributions: contributions,
      capability_contributions_at_next_level: next_contributions,
      promotion_readiness: readiness
    }

    Views::Assessments::HeroSummary.new(
      scoring: scoring, self_scoring: scoring, manager_scoring: scoring, categories: categories, person_level: person_level,
      merged_levels: levels, mastery_threshold: 1.5, meeting_expectation_threshold: 0.95,
      underperforming_threshold: 0.8, assessment_id: SecureRandom.uuid_v7, context: context,
      viewer_can_rate: false
    ).call
  end

  context "the score bar" do
    should "run 0–200 with the level codes as tick labels" do
      html = render_hero(state: :performing, components: { prior: 1.0, current: 1.0, next: 0.38, score: 1.38 })
      assert_includes html, 'aria-valuemax="200"'
      assert_includes html, 'aria-valuenow="138"'
      assert_includes html, "100% · E3"
      assert_includes html, "200% · E4"
    end

    should "collapse to a single 0–100 segment at the top of the ladder" do
      html = render_hero(state: :top_of_ladder, person_level: 4,
                         components: { prior: 1.0, current: 1.0, next: 0.0, score: 1.0 })
      assert_includes html, 'aria-valuemax="100"'
      assert_not_includes html, "200%"
    end
  end

  context "the verdict and gloss" do
    should "name the score's parts" do
      html = render_hero(state: :performing, components: { prior: 0.95, current: 0.94, next: 0.38, score: 1.27 })
      assert_includes html, "You&#39;re meeting E3 expectations."
      assert_includes html, "94% of E3 demonstrated · 38% of the way to E4 · 5% missing below E3."
    end

    should "point at the next level once past the mastery waypoint" do
      html = render_hero(state: :mastering, components: { prior: 1.0, current: 1.0, next: 0.62, score: 1.62 })
      assert_includes html, "You&#39;re well on the way to E4."
      assert_includes html, "Mastering E3 · 62% of the way to E4"
      assert_includes html, "Gap to E4"
    end

    should "say what holds a meeting score back when a capability is blocked" do
      html = render_hero(state: :progressing, statuses: { "cap-a" => :blocked },
                         components: { prior: 1.0, current: 1.0, next: 0.0, score: 1.0 })
      assert_includes html, "You&#39;re held back at E3 by 1 blocked capability."
      assert_includes html, "text-amber-700", "a blocked score is coloured like its verdict, not its number"
    end

    should "colour the number and bar by state" do
      html = render_hero(state: :mastering, components: { prior: 1.0, current: 1.0, next: 0.62, score: 1.62 })
      assert_includes html, "text-purple-600"
      assert_includes html, "bg-purple-500"
    end

    should "read as the top of the ladder when there is no level above" do
      html = render_hero(state: :top_of_ladder, person_level: 4,
                         components: { prior: 1.0, current: 1.0, next: 0.0, score: 1.0 })
      assert_includes html, "the top of the ladder."
      assert_includes html, "no level above E4"
      assert_includes html, "Strongest at E4"
    end

    should "celebrate promotion readiness" do
      html = render_hero(state: :eligible, readiness: { eligible: true, blocked_at_next_level: [] },
                         components: { prior: 1.0, current: 1.0, next: 1.0, score: 2.0 })
      assert_includes html, "demonstrating E4 expectations — promotion ready."
      assert_includes html, "Eligible for promotion to E4"
    end

    should "address the assessee in the third person for a manager" do
      html = render_hero(state: :performing, context: :manager,
                         components: { prior: 1.0, current: 1.0, next: 0.2, score: 1.2 })
      assert_includes html, "They&#39;re meeting E3 expectations."
    end
  end
end
