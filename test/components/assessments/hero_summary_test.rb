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
  MORE_CAPS = (CAPS + [ "Mentoring", "Delivery", "Ownership" ]).freeze

  # #418: the rows used to print a weight-unit delta — "-1.0" for every
  # capability nobody had rated at the next level, so three rows ranked
  # nothing and the number could not be read against an expectation.
  def render_gap_list(next_scores:, state: :mastering, here_scores: nil, blocked: nil, weights: {}, names: CAPS)
    capabilities = names.each_with_index.map do |name, i|
      { capability: CAP.new(stable_id: "cap-#{i}", name: name),
        weight: weights.fetch("cap-#{i}", 1.0),
        cells: { 3 => { current_frequency: "consistent" } } }
    end
    here_scores ||= names.each_with_index.to_h { |_, i| [ "cap-#{i}", 1.0 ] }
    scoring = {
      performance_ratio: 1.62,
      components: { prior: 1.0, current: 1.0, next: 0.62, score: 1.62, bands_above: 1 },
      performance_state: state,
      capability_scores: scored(here_scores),
      capability_scores_at_next_level: scored(next_scores),
      promotion_readiness: blocked ? { blocked_at_next_level: blocked } : nil
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
                  cells: nil, self_scoring: nil, viewer_can_rate: false, unrated: [])
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
      unrated: unrated,
      capability_scores: scored(scores),
      capability_scores_at_next_level: scored(next_scores),
      promotion_readiness: readiness
    }

    Views::Assessments::HeroSummary.new(
      scoring: scoring, self_scoring: self_scoring || scoring, manager_scoring: scoring,
      categories: categories, person_level: person_level,
      merged_levels: levels, assessment_id: SecureRandom.uuid_v7, context: context,
      viewer_can_rate: viewer_can_rate
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
    should "mark a capability that counts more than ×1, and only that one" do
      html = render_gap_list(next_scores: { "cap-0" => 0.5, "cap-1" => 0.25, "cap-2" => 0.0 },
                             weights: { "cap-1" => 2.0 })

      assert_includes html, 'aria-describedby="assessment-term-weight-hero-cap-1"'
      assert_includes html, "×2"
      assert_not_includes html, "assessment-term-weight-hero-cap-0"
      assert_not_includes html, "assessment-term-weight-hero-cap-2"
    end

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

    should "break a tie on the level the person is standing on" do
      # Nothing is rated at the next level until someone starts working
      # there, so a whole gap list sitting at 0% of it is the common case,
      # not an edge one. The capability weakest at E3 has furthest to go.
      html = render_gap_list(
        next_scores: { "cap-0" => 0.0, "cap-1" => 0.0, "cap-2" => 0.0 },
        here_scores: { "cap-0" => 1.0, "cap-1" => 0.6, "cap-2" => 0.9 }
      )

      assert_operator html.index("Quality First"), :<, html.index("DevSecOps")
      assert_operator html.index("DevSecOps"), :<, html.index("Strategic Thinking")
    end

    should "name the level it is actually showing when the one above has no expectations" do
      # A next level exists in the ladder but carries no expectations yet,
      # so there is nothing to be short of there. Falling back to the
      # assessed level under a "Gap to E4" label would read a 100% at E3
      # as E4 demonstrated in full.
      html = render_gap_list(next_scores: {}, state: :performing,
                             here_scores: { "cap-0" => 1.0, "cap-1" => 0.9, "cap-2" => 0.8 })

      # Raw HTML here — Tailwind's `uppercase` is visual only.
      assert_includes html, "Gap to E3"
      assert_not_includes html, "Gap to E4"
    end

    should "not rank a capability with no assessed-level expectation as the weakest" do
      # Its absence from the assessed level means nothing was asked of it
      # there, which must not become a zero that wins the tie-break.
      #
      # DevSecOps (absent from `here_scores`) is listed FIRST so that
      # insertion order alone would put it at the top: with the tie-break
      # removed entirely the rows would come out in map order and this
      # assertion would fail, and with the absent-score fallback removed
      # its 0.0 would win outright. Either regression is caught.
      html = render_gap_list(
        next_scores: { "cap-2" => 0.0, "cap-0" => 0.0, "cap-1" => 0.0 },
        here_scores: { "cap-0" => 0.4, "cap-1" => 0.6 }
      )

      assert_operator html.index("Strategic Thinking"), :<, html.index("DevSecOps"),
        "the capability with no assessed-level expectation must not lead the gap list"
      assert_operator html.index("Quality First"), :<, html.index("DevSecOps"),
        "both capabilities that DO carry an assessed-level expectation rank ahead of it"
    end

    should "rank blocked capabilities among themselves, not by collection order" do
      # `blocked_at_next_level` arrives in whatever order the engine
      # collected it, so taking the first three could omit a worse one and
      # show the rest out of order.
      html = render_gap_list(
        next_scores: { "cap-0" => 0.4, "cap-1" => 0.1, "cap-2" => 0.7 },
        blocked: [ "cap-2", "cap-0", "cap-1" ]
      )

      assert_operator html.index("Quality First"), :<, html.index("Strategic Thinking")
      assert_operator html.index("Strategic Thinking"), :<, html.index("DevSecOps")
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

  context "a gap list longer than the panel" do
    # #471: three rows read as the whole list. A reader rated one, watched a
    # fourth take its place, and concluded three stood between them and E3.
    should "say how many more are short of the level, and jump to the next one" do
      html = render_gap_list(
        names: MORE_CAPS,
        next_scores: { "cap-0" => 0.5, "cap-1" => 0.25, "cap-2" => 0.0,
                       "cap-3" => 0.6, "cap-4" => 0.75, "cap-5" => 1.0 }
      )

      # cap-5 meets E4, so only two of the remaining three are gaps.
      assert_includes html, "+2 more short of E4"
      # The fourth-weakest gap (Mentoring, 60%) at E4 is where it lands.
      assert_includes html, 'href="#cell-cap-3-4"'
      assert_includes html, 'data-continue-assessing-level-ordinal-value="4"'
      assert_not_includes html, "Mentoring"
    end

    should "count gaps at the assessed level when the panel names it" do
      html = render_gap_list(
        names: MORE_CAPS, state: :underperforming, next_scores: {},
        here_scores: { "cap-0" => 0.2, "cap-1" => 0.3, "cap-2" => 0.4,
                       "cap-3" => 0.5, "cap-4" => 1.0, "cap-5" => 1.2 }
      )

      assert_includes html, "Gap to E3"
      assert_includes html, "+1 more short of E3"
      assert_includes html, 'href="#cell-cap-3-3"'
    end

    should "add nothing when every gap is already listed" do
      html = render_gap_list(next_scores: { "cap-0" => 0.5, "cap-1" => 0.25, "cap-2" => 0.0 })

      assert_includes html, "Gap to E4"
      assert_not_includes html, "more short of"
    end

    should "never list a capability already demonstrated in full as a gap" do
      html = render_gap_list(next_scores: { "cap-0" => 1.0, "cap-1" => 0.25, "cap-2" => 1.3 })

      assert_includes html, "Quality First"
      assert_not_includes html, "Strategic Thinking"
      assert_not_includes html, "DevSecOps"
      assert_not_includes html, "more short of"
    end

    should "say so when nothing is short of the level" do
      html = render_gap_list(state: :performing,
                             next_scores: { "cap-0" => 1.0, "cap-1" => 1.0, "cap-2" => 1.1 })

      assert_includes html, "Gap to E4"
      assert_includes html, "No gaps to E4"
      assert_not_includes html, "Strategic Thinking"
    end

    should "cut a tied list the same way on every render" do
      # Everyone at 0% of E4 and 100% of E3 is the common case. Unbroken,
      # the rows and the "+N more" target could reshuffle on each reload.
      ties = MORE_CAPS.each_index.to_h { |i| [ "cap-#{i}", 0.0 ] }
      html = render_gap_list(names: MORE_CAPS, next_scores: ties.to_a.reverse.to_h)

      assert_operator html.index("Strategic Thinking"), :<, html.index("Quality First")
      assert_operator html.index("Quality First"), :<, html.index("DevSecOps")
      assert_includes html, 'href="#cell-cap-3-4"'
    end

    should "lead with blocked capabilities and still count the rest" do
      html = render_gap_list(
        names: MORE_CAPS,
        next_scores: { "cap-0" => 0.1, "cap-1" => 0.2, "cap-2" => 0.3,
                       "cap-3" => 0.9, "cap-4" => 0.4, "cap-5" => 0.5 },
        blocked: [ "cap-3" ]
      )

      # Blocked Mentoring leads despite the higher score; the other five
      # gaps rank weakest first, two shown and three counted.
      assert_operator html.index("Mentoring"), :<, html.index("Strategic Thinking")
      assert_operator html.index("Strategic Thinking"), :<, html.index("Quality First")
      assert_not_includes html, "DevSecOps"
      assert_includes html, "+3 more short of E4"
      assert_includes html, 'href="#cell-cap-2-4"'
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
      assert_includes render_with_diverging_self, "bg-warning-strong"
    end

    should "leave an agreeing perspective unmarked" do
      html = render_hero(context: :manager, state: :performing,
                         components: { prior: 1.0, current: 1.0, next: 0.0, score: 1.0 })

      assert_includes html, "Self: 100%"
      assert_not_includes html, "bg-warning-strong"
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
      assert_includes html, "text-score-progressing", "a blocked score is coloured like its verdict, not its number"
    end

    # #485: an unrated capability is not a judgement, so it is never counted
    # as blocked — but it still holds the state, and the headline says why.
    should "say the state waits on a rating, never that it is blocked" do
      html = render_hero(state: :progressing, statuses: { "cap-a" => :unrated }, unrated: [ "cap-a" ],
                         components: { prior: 1.0, current: 1.0, next: 0.0, score: 1.0 })
      assert_includes html, "You&#39;re held at E3 until 1 capability is rated."
      assert_not_includes html, "blocked"
    end

    should "not promise a rating lifts a score below the bar" do
      html = render_hero(state: :progressing, statuses: { "cap-a" => :unrated }, unrated: [ "cap-a" ],
                         components: { prior: 1.0, current: 0.85, next: 0.0, score: 0.85 })
      assert_includes html, "You&#39;re close to E3 expectations, with 1 capability still to rate."
      assert_not_includes html, "until"
    end

    should "name blocked and unrated capabilities apart" do
      html = render_hero(state: :progressing, statuses: { "cap-a" => :blocked, "cap-b" => :unrated, "cap-c" => :unrated },
                         unrated: [ "cap-b", "cap-c" ],
                         components: { prior: 1.0, current: 1.0, next: 0.0, score: 1.0 })
      assert_includes html, "You&#39;re held back at E3 by 1 blocked capability, with 2 capabilities still to rate."
    end

    should "say what promotion waits on without calling an unrated capability blocked" do
      html = render_hero(state: :performing,
                         readiness: { eligible: false, blocked_at_next_level: [ "cap-b" ], unrated_at_next_level: [ "cap-a", "cap-c" ] },
                         components: { prior: 1.0, current: 1.0, next: 0.4, score: 1.4 })
      assert_includes html, "Blocked by 1 capability · 2 capabilities to rate at E4"
    end

    should "colour the number and bar by state" do
      html = render_hero(state: :mastering, components: { prior: 1.0, current: 1.0, next: 0.62, score: 1.62 })
      assert_includes html, "text-score-ahead"
      assert_includes html, "bg-score-ahead"
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

  # #480: with every cell holding a value, the work left was invisible.
  context "carried ratings left to confirm" do
    should "name them and jump to the first once every cell has a value" do
      html = render_hero(state: :performing, components: { prior: 1.0, current: 1.0, next: 0.0, score: 1.0 },
                         cells: { 3 => { current_frequency: "consistent", current_frequency_carried: true } },
                         viewer_can_rate: true)
      link = Nokogiri::HTML5.fragment(html).at_css("a[href='#cell-cap-a-3']")

      assert_equal "1 to confirm→", link&.text
      assert_includes link["class"], "border-dashed"
    end

    should "not offer it to a viewer who can't rate" do
      html = render_hero(state: :performing, components: { prior: 1.0, current: 1.0, next: 0.0, score: 1.0 },
                         cells: { 3 => { current_frequency: "consistent", current_frequency_carried: true } })

      assert_not_includes html, "to confirm"
    end
  end

  # The agreed score counts an unagreed cell as 0.
  def render_alignment(agreed:, awaiting: true)
    caps = [ CAP.new(stable_id: "cap-a", name: "Strategic Thinking"), CAP.new(stable_id: "cap-b", name: "Delivery") ]
    capabilities = caps.each_with_index.map do |cap, i|
      { capability: cap,
        cells: { 3 => { manager_frequency: "consistent", aligned_frequency: (i < agreed ? "consistent" : nil) } } }
    end
    agreed_scoring = { performance_ratio: 0.47, performance_state: :underperforming,
                       components: { prior: 1.0, current: 0.47, next: 0.0, score: 0.47, bands_above: 1 },
                       capability_scores: scored({ "cap-a" => 1.0, "cap-b" => 0.0 }),
                       capability_scores_at_next_level: scored({}) }
    manager_scoring = { performance_ratio: 1.09, performance_state: :performing,
                        components: { prior: 1.0, current: 1.0, next: 0.09, score: 1.09, bands_above: 1 } }

    Views::Assessments::HeroSummary.new(
      scoring: agreed_scoring, aligned_scoring: agreed_scoring, manager_scoring: manager_scoring,
      categories: [ { category: nil, awaiting_agreement: awaiting, capabilities: capabilities } ], person_level: 3,
      merged_levels: LEVELS, assessment_id: SecureRandom.uuid_v7, context: :alignment,
      viewer_is_manager: true, viewer_can_rate: true, assessee_name: "Alex Developer"
    ).call
  end

  context "alignment before every cell is agreed" do
    should "count what is agreed instead of scoring it" do
      html = render_alignment(agreed: 1)
      panel = Nokogiri::HTML5.fragment(html).at_css("#scoring-panel")

      assert_includes html, "The score appears once everything is agreed"
      assert_includes html, "1 of 2 E3 capabilities still to agree."
      assert_includes panel.text, "1/2agreed"
      assert_includes html, "Score unlocks at 2"
      assert_includes html, "Agree next capability"
      assert_not_includes panel.text, "47%", "the half-agreed score must not show"
    end

    should "keep the manager's own percentage beside the count" do
      html = render_alignment(agreed: 1)

      assert_includes Nokogiri::HTML5.fragment(html).at_css("#hero-secondary-percents")&.text.to_s, "Mgr: 109%"
    end

    should "score once the last cell is agreed" do
      html = render_alignment(agreed: 2)

      assert_not_includes html, "The score appears once everything is agreed"
      assert_includes html, "47%"
    end

    # A completed record, or another level read through the lens, has
    # nothing left to agree — withholding there would hide the score for good.
    should "keep scoring when there is nothing left to agree" do
      html = render_alignment(agreed: 1, awaiting: false)

      assert_not_includes html, "The score appears once everything is agreed"
      assert_includes html, "47%"
    end
  end

  def radar_trigger(html)
    Nokogiri::HTML5.fragment(html).at_css("button[data-modal-target-id='#{Views::Assessments::CapabilityMapModal::ID}']")
  end

  context "the capability radar" do
    should "open the capability map from the header once there is a score" do
      html = render_hero(state: :mastering, components: { prior: 1.0, current: 1.0, next: 0.6, score: 1.6 })
      trigger = radar_trigger(html)

      assert trigger, "expected the compact radar to open the capability map"
      assert_equal "modal#open", trigger["data-action"]
      assert trigger.at_css("svg[aria-hidden='true']"), "expected the compact radar inside the trigger"
      assert_includes trigger["aria-label"], "Open the capability map"
    end

    should "wait, with the score, until enough is rated" do
      html = render_hero(state: :progressing, components: { prior: 1.0, current: 0.0, next: 0.0, score: 0.0 },
                         cells: { 3 => { current_frequency: nil } })

      assert_nil radar_trigger(html)
    end
  end
end
