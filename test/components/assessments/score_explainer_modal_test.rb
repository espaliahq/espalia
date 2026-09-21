# frozen_string_literal: true

require "test_helper"

# "How is this calculated?" (#414) — the viewer's own arithmetic first,
# then the rules. A person looking at 158% wants to know where 158 came
# from, not to read a definition and do the sum themselves.
class Views::Assessments::ScoreExplainerModalTest < ActiveSupport::TestCase
  LEVELS = [
    { ordinal: 3, level_code: "E3" }, { ordinal: 4, level_code: "E4" }
  ].freeze

  def render_modal(components:, state: :mastering, person_level: 3, subject: "Your score",
                   second_person: true, emphasised: [],
                   thresholds: { underperforming: 0.8, meeting: 0.95, mastering: 1.5 })
    Views::Assessments::ScoreExplainerModal.new(
      components: components, state: state, subject: subject, second_person: second_person,
      merged_levels: LEVELS, person_level: person_level, thresholds: thresholds,
      emphasised: emphasised
    ).call
  end

  context "the capabilities that count differently" do
    should "name each one with the chips the card wears" do
      html = render_modal(
        components: { prior: 1.0, current: 1.0, next: 0.0, score: 1.0 },
        emphasised: [
          { stable_id: "cap-a", name: "Critical Thinking", weight: 2.0, required: true },
          { stable_id: "cap-b", name: "Delivery", weight: 1.0, required: true }
        ]
      )
      section = html[/Counts differently for this role.*?How it adds up/m]

      assert section, "expected the counts-differently section"
      assert_includes section, "Critical Thinking"
      assert_includes section, "×2"
      assert_equal 2, section.scan(">Required<").size
      assert_not_includes section, "×1"
    end

    should "say nothing when every capability counts ×1 and tolerates a gap" do
      html = render_modal(components: { prior: 1.0, current: 1.0, next: 0.0, score: 1.0 })
      assert_not_includes html, "Counts differently"
    end
  end

  context "the viewer's own arithmetic" do
    should "show the parts and the total they add up to" do
      html = render_modal(components: { prior: 1.0, current: 0.97, next: 0.61, score: 1.58 })

      assert_includes html, "Shown at E3"
      assert_includes html, "97%"
      assert_includes html, "Shown above E3"
      assert_includes html, "61%"
      assert_includes html, "158%"
    end

    should "show what is missing below only when something is" do
      whole = render_modal(components: { prior: 1.0, current: 1.0, next: 0.0, score: 1.0 })
      short = render_modal(components: { prior: 0.95, current: 1.0, next: 0.0, score: 0.95 })

      assert_not_includes whole, "Missing below E3"
      assert_includes short, "Missing below E3"
      assert_includes short, "5%"
    end

    # Rounding each row on its own produced 11% + 11% under a score of 23%
    # — in the one panel whose whole job is showing the sum.
    should "add up to the total beneath them" do
      html = render_modal(components: { prior: 1.0, current: 0.114, next: 0.114, score: 0.228 })

      sum_panel = html[/today.*?How it adds up/m]
      rows = sum_panel.scan(/([+−]?)(\d+)%/).map { |sign, value| sign == "−" ? -value.to_i : value.to_i }
      parts, total = rows[0..-2], rows.last

      assert_equal total, parts.sum,
                   "breakdown #{parts.inspect} does not add up to #{total}"
    end

    should "name whose numbers these are" do
      html = render_modal(components: { prior: 1.0, current: 1.0, next: 0.0, score: 1.0 },
                          subject: "Alex's score")

      assert_includes html, "Alex&#39;s score today"
    end
  end

  context "the rules" do
    should "quote the framework's configured bands" do
      html = render_modal(components: { prior: 1.0, current: 1.0, next: 0.0, score: 1.0 },
                          thresholds: { underperforming: 0.6, meeting: 0.75, mastering: 1.25 })

      assert_includes html, "60%"
      assert_includes html, "125%"
    end

    should "explain the one rule people are most surprised by" do
      html = render_modal(components: { prior: 1.0, current: 1.0, next: 0.0, score: 1.0 })

      assert_includes html, "counts in proportion to how consistently"
      assert_includes html, "does not cover for E3"
    end

    # Required, weight and Carried change the number but are never printed
    # on the page, so there is nothing for a tip to hang off — the drawer
    # is where they get defined instead.
    should "define the rules the page never prints a word for" do
      html = render_modal(components: { prior: 1.0, current: 1.0, next: 0.0, score: 1.0 })

      assert_includes html, "Some capabilities count for more or less than others"
      assert_includes html, "marked Required"
      assert_includes html, "carried from the last cycle"
    end

    # A definition is read in two places: beside the word it defines, and
    # here as a bullet with no word beside it. Tip-shaped copy — "This
    # capability counts for more", "nobody has rated here yet" — points at
    # something this list cannot show. (A term rendered ONLY as a tip, like
    # Blocked on its badge, is free to point at it — hence asserting on the
    # drawer's output rather than on every term in the glossary.)
    should "read without a word beside it to point at" do
      html = render_modal(components: { prior: 1.0, current: 1.0, next: 0.0, score: 1.0 })
      body = html[/How it adds up.*/m].downcase

      [ "this capability", "this rating", "here yet", "shown here" ].each do |phrase|
        assert_not_includes body, phrase,
          "a bullet points at something the list cannot show: '#{phrase}'"
      end
    end

    should "say plainly that feedback is not an input" do
      html = render_modal(components: { prior: 1.0, current: 1.0, next: 0.0, score: 1.0 })

      assert_includes html, "What doesn&#39;t count"
      assert_includes html, "never an input to it"
    end
  end

  context "who the reader is" do
    should "speak to the assessee on their own page" do
      html = render_modal(components: { prior: 1.0, current: 1.0, next: 0.5, score: 1.5 })

      assert_includes html, "what E3 expects you show"
      assert_includes html, "What you show at E4"
    end

    should "speak about the report on a manager's page" do
      # A manager reading "what E3 expects you already show" about their
      # report is being told the wrong thing.
      html = render_modal(components: { prior: 1.0, current: 1.0, next: 0.5, score: 1.5 },
                          subject: "Alex's score", second_person: false)

      assert_includes html, "what E3 expects they show"
      assert_includes html, "What they show at E4"
      assert_not_includes html, "expects you show"
    end
  end

  context "at the top of the ladder" do
    should "not promise a level above" do
      html = render_modal(components: { prior: 1.0, current: 1.0, next: 0.0, score: 1.0 },
                          person_level: 4, state: :top_of_ladder)

      assert_not_includes html, "above E4",
        "nothing may name a level above the top of the ladder — not the row, not the Required rule"
      assert_includes html, "no level above it"
      # The gate rule explains credit earned at the level above. There
      # isn't one here, so describing it promises a band nobody can reach.
      assert_includes html, "there is no level above to earn more"
      assert_not_includes html, "counts once E4 itself is consistent"
    end
  end
end
