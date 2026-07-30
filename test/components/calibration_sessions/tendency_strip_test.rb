# frozen_string_literal: true

require "test_helper"

# The Carried column and the emphasis rules it drives. Rendered directly
# rather than through the session page, because the interesting cases (an
# entirely-carried rater; a carried manager row against fresh self-ratings)
# are awkward to seed end-to-end and the logic is all in the view.
class Views::CalibrationSessions::TendencyStripTest < ActiveSupport::TestCase
  RATER_ID = "rater-1"

  def rater(**overrides)
    {
      participant_id: RATER_ID, report_count: 3, rated_count: 3, cell_count: 10,
      mean: 2.5, org_delta: 0.9,
      distribution: { "none" => 0, "some" => 0, "occasional" => 5, "consistent" => 5 },
      self_gap: nil, evidence_pct: 0.5, carried_count: 0, small_n: false
    }.merge(overrides)
  end

  def render_strip(row)
    people = { RATER_ID => Person.new(name: "Mia Manager") }
    Views::CalibrationSessions::TendencyStrip.new(
      org_mean: 1.6, raters: [ row ], people: people
    ).call
  end

  context "the Carried column" do
    should "show a dash when nothing was carried" do
      html = render_strip(rater(carried_count: 0))

      assert_includes html, "Carried"
      assert_not_includes html, " of 10"
    end

    should "show the count out of the rater's cells" do
      assert_includes render_strip(rater(carried_count: 4)), "4 of 10"
    end

    should "say \"all\" when every cell was carried" do
      html = render_strip(rater(carried_count: 10))

      assert_includes html, ">all 10<", "the visible label reads \"all 10\""
      assert_includes html, "10 of 10 ratings carried forward",
        "the full count still rides the title, for anyone who wants the number"
    end
  end

  context "emphasis on an all-carried row" do
    should "drop the org-delta arrow emphasis — an unexpressed tendency isn't a coaching conversation" do
      emphasised = render_strip(rater(carried_count: 0, org_delta: 0.9))
      all_carried = render_strip(rater(carried_count: 10, org_delta: 0.9))

      assert_includes emphasised, "text-amber-700"
      # Only the Carried cell's own amber remains, not the org-delta's.
      assert_equal 1, all_carried.scan("text-amber-700").size
      assert_includes all_carried, "+0.9"
    end

    should "KEEP the self-gap warning — the reports' own ratings are fresh" do
      html = render_strip(rater(carried_count: 10, self_gap: -1.2))

      assert_includes html, "⚠",
        "a manager coasting on last cycle while their reports rate themselves " \
        "higher this cycle is the most actionable row on the strip"
    end
  end
end
