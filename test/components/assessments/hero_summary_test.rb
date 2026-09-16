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

  # A capability score map in the shape the builder hands the hero — the
  # state derived from the default thresholds so call sites stay a number.
  def scored(map)
    map.transform_values do |value|
      state = if value < 0.8 then :underperforming
      elsif value < 0.95 then :progressing
      elsif value < 1.5 then :performing
      else :mastering
      end
      { score: value, scorable: true, state: state }
    end
  end

  CAPS = [ "Strategic Thinking", "Quality First", "DevSecOps" ].freeze

  # #418: the rows used to print a weight-unit delta — "-1.0" for every
  # capability nobody had rated at the next level, so three rows ranked
  # nothing and the number could not be read against an expectation.
  def render_gap_list(next_scores:, state: :mastering)
    capabilities = CAPS.each_with_index.map do |name, i|
      { capability: CAP.new(stable_id: "cap-#{i}", name: name),
        cells: { 3 => { current_frequency: "consistent" } } }
    end
    scoring = {
      performance_ratio: 1.62,
      components: { prior: 1.0, current: 1.0, next: 0.62, score: 1.62, bands_above: 1 },
      performance_state: state,
      capability_scores: scored(CAPS.each_with_index.to_h { |_, i| [ "cap-#{i}", 1.0 ] }),
      capability_scores_at_next_level: scored(next_scores),
      promotion_readiness: nil
    }
    Views::Assessments::HeroSummary.new(
      scoring: scoring, self_scoring: scoring, manager_scoring: scoring,
      categories: [ { category: nil, capabilities: capabilities } ],
      person_level: 3, merged_levels: LEVELS, assessment_id: SecureRandom.uuid_v7,
      context: :self, viewer_can_rate: false
    ).call
  end

  def render_hero(state:, components:, person_level: 3, levels: LEVELS, statuses: {}, readiness: nil,
                  scores: { "cap-a" => 1.0 }, next_scores: { "cap-a" => 0.25 }, context: :self,
                  cells: nil, self_scoring: nil)
    cap = CAP.new(stable_id: "cap-a", name: "Strategic Thinking")
    cells ||= { person_level => {
      current_frequency: "consistent", manager_frequency: "consistent", aligned_frequency: "consistent"
    } }
    categories = [ { category: nil, capabilities: [ { capability: cap, cells: cells } ] } ]
    scoring = {
      performance_ratio: components[:score],
      components: { bands_above: 1 }.merge(components),
      performance_state: state,
      meeting_expectations: components[:score] >= 0.95,
      mastering: components[:score] >= 1.5,
      capability_statuses: statuses,
      capability_scores: scored(scores),
      capability_scores_at_next_level: scored(next_scores),
      promotion_readiness: readiness
    }

    Views::Assessments::HeroSummary.new(
      scoring: scoring, self_scoring: self_scoring || scoring, manager_scoring: scoring,
      categories: categories, person_level: person_level,
      merged_levels: levels, assessment_id: SecureRandom.uuid_v7, context: context,
      viewer_can_rate: false
    ).call
  end

  # A quick indicator beside the number it differs from — the state
  # vocabulary is the primary verdict's job, once, at the top.
  def render_with_diverging_self
    render_hero(
      context: :manager, state: :mastering,
      components: { prior: 1.0, current: 1.0, next: 0.58, score: 1.58 },
      self_scoring: {
        performance_ratio: 0.1, components: { prior: 1.0, current: 0.1, next: 0.0, score: 0.1, bands_above: 1 },
        performance_state: :underperforming, capability_scores: scored({ "cap-a" => 0.1 })
      }
    )
  end

  context "the score bar" do
    should "run 0–200 with the level codes as tick labels" do
      html = render_hero(state: :performing, components: { prior: 1.0, current: 1.0, next: 0.38, score: 1.38 })
      assert_includes html, 'aria-valuemax="200"'
      assert_includes html, 'aria-valuenow="138"'
      assert_includes html, "100% · E3"
      assert_includes html, "200% · E4"
    end

    should "run to 300 with two bands above when the cap allows it" do
      html = render_hero(state: :mastering, levels: LEVELS + [ { ordinal: 5, level_code: "E5" } ],
                         components: { prior: 1.0, current: 1.0, next: 1.4, score: 2.4, bands_above: 2 })
      assert_includes html, 'aria-valuemax="300"'
      assert_includes html, "300% · E5"
      assert_includes html, "E4 demonstrated in full · 40% of the way to E5"
    end

    should "collapse to a single 0–100 segment at the top of the ladder" do
      html = render_hero(state: :top_of_ladder, person_level: 4,
                         components: { prior: 1.0, current: 1.0, next: 0.0, score: 1.0 })
      assert_includes html, 'aria-valuemax="100"'
      assert_not_includes html, "200%"
    end
  end

  context "the gap list" do
    should "read each row as a percentage of the level the panel names" do
      html = render_gap_list(next_scores: { "cap-0" => 0.5, "cap-1" => 0.25, "cap-2" => 0.0 })

      assert_includes html, "Gap to E4"
      assert_includes html, "50%"
      assert_includes html, "25%"
      assert_not_includes html, "-1.0"
      assert_not_includes html, "+0.0"
    end

    should "rank a capability shown at the next level above one never shown there" do
      html = render_gap_list(next_scores: { "cap-0" => 0.5, "cap-1" => 0.25, "cap-2" => 0.0 })

      # Weakest first: DevSecOps (0%), Quality First (25%), Strategic (50%).
      assert_operator html.index("DevSecOps"), :<, html.index("Quality First")
      assert_operator html.index("Quality First"), :<, html.index("Strategic Thinking")
    end

    should "leave out a capability with no expectation at that level" do
      # It owes nothing there, so its unavoidable 0 must not rank as the
      # worst thing on the page.
      scoring_scores = scored({ "cap-0" => 0.5, "cap-1" => 0.25 })
      scoring_scores["cap-2"] = { score: 0.0, scorable: false, state: :underperforming }
      capabilities = CAPS.each_with_index.map do |name, i|
        { capability: CAP.new(stable_id: "cap-#{i}", name: name),
          cells: { 3 => { current_frequency: "consistent" } } }
      end
      scoring = {
        performance_ratio: 1.62,
        components: { prior: 1.0, current: 1.0, next: 0.62, score: 1.62, bands_above: 1 },
        performance_state: :mastering,
        capability_scores: scored(CAPS.each_with_index.to_h { |_, i| [ "cap-#{i}", 1.0 ] }),
        capability_scores_at_next_level: scoring_scores,
        promotion_readiness: nil
      }
      html = Views::Assessments::HeroSummary.new(
        scoring: scoring, self_scoring: scoring, manager_scoring: scoring,
        categories: [ { category: nil, capabilities: capabilities } ],
        person_level: 3, merged_levels: LEVELS, assessment_id: SecureRandom.uuid_v7,
        context: :self, viewer_can_rate: false
      ).call

      assert_includes html, "Quality First"
      assert_not_includes html, "DevSecOps"
    end
  end

  context "the other perspectives" do
    should "read as a percentage, never a second state word" do
      html = render_with_diverging_self

      assert_includes html, "Self: 10%"
      assert_not_includes html, "Self: Below expectations"
      assert_not_includes html, "Below expectations"
    end

    should "mark a perspective that lands in a different state" do
      assert_includes render_with_diverging_self, "bg-amber-400"
    end

    should "leave an agreeing perspective unmarked" do
      html = render_hero(context: :manager, state: :performing,
                         components: { prior: 1.0, current: 1.0, next: 0.0, score: 1.0 })

      assert_includes html, "Self: 100%"
      assert_not_includes html, "bg-amber-400"
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

    should "read as unscorable when the assessed level has no expectations" do
      html = render_hero(state: :underperforming, cells: {},
                         components: { prior: 1.0, current: 0.0, next: 0.0, score: 0.0 })
      assert_includes html, "Nothing to score at E3 yet"
      assert_not_includes html, "Below E3 expectations"
      assert_not_includes html, "hero-score-bar"
    end

    should "address the assessee in the third person for a manager" do
      html = render_hero(state: :performing, context: :manager,
                         components: { prior: 1.0, current: 1.0, next: 0.2, score: 1.2 })
      assert_includes html, "They&#39;re meeting E3 expectations."
    end
  end
end
