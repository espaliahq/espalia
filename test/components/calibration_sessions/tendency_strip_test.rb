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

  # An unrated rater beside a RATED one — an all-unrated strip renders the
  # card-level empty state instead, and these are about one row inside a
  # live table. (Class-level: shoulda-context can't see defs inside a
  # context block.)
  def render_mixed_strip
    unrated = rater(participant_id: "rater-2", cell_count: 0, rated_count: 0,
                    mean: nil, org_delta: nil, self_gap: nil, evidence_pct: nil,
                    distribution: { "none" => 0, "some" => 0,
                                    "occasional" => 0, "consistent" => 0 })
    people = { RATER_ID => Person.new(name: "Mia Manager"),
               "rater-2" => Person.new(name: "Quinn Alderberry") }
    Views::CalibrationSessions::TendencyStrip.new(
      org_mean: 1.6, raters: [ rater, unrated ], people: people
    ).call
  end

  context "a rater with nothing rated" do
    should "say so instead of rendering zeroed columns" do
      html = render_mixed_strip

      assert_includes html, "No ratings yet"
      assert_includes html, "not counted in the org mean"
      # Exactly ONE distribution bar — the rated rater's. A second, zeroed
      # bar would render the unrated row as a measurement.
      assert_equal 1, html.scan("Rating distribution").size
      assert_includes html, "Quinn Alderberry"
    end

    should "keep the full columns for a rated rater" do
      assert_not_includes render_strip(rater), "No ratings yet"
    end
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

  # Carried ratings are still the rater's ratings — leaving them unrevisited
  # is a decision they own — so the flags fire exactly as on fresh values.
  # The Carried column marks how the row got there; it never softens it.
  context "a carried row is not exempt from the flags" do
    should "keep the org-delta emphasis when the whole row is carried" do
      fresh = render_strip(rater(carried_count: 0, org_delta: 0.9))
      carried = render_strip(rater(carried_count: 10, org_delta: 0.9))

      assert_includes fresh, "text-amber-700"
      # Both the org-delta cell AND the Carried cell are amber.
      assert_equal 2, carried.scan("text-amber-700").size,
        "a tendency built from values the rater declined to revisit is still theirs"
      assert_includes carried, "+0.9"
    end

    should "keep the self-gap warning when the whole row is carried" do
      html = render_strip(rater(carried_count: 10, self_gap: -1.2))

      assert_includes html, "⚠",
        "the reports' self-ratings are fresh, so the gap is live: they have " \
        "formed a view this cycle that disagrees with the carried record"
    end

    should "still mark the row as carried while flagging it" do
      html = render_strip(rater(carried_count: 10, org_delta: 0.9, self_gap: -1.2))

      assert_includes html, ">all 10<"
      assert_includes html, "⚠"
    end
  end
end
