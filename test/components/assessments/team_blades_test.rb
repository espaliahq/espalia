# frozen_string_literal: true

require "test_helper"

# The team's blades, with a line across each at the group's score.
class Views::Assessments::TeamBladesTest < ActiveSupport::TestCase
  def capability(stable_id, score:, group_median:)
    { stable_id:, name: stable_id, category_id: "cat", category_name: "Craft", hue: Assessments::CapabilityShape::HUES.first, score:, scored: 2, short: 0,
      group_median: }
  end

  def picture(capabilities)
    Nokogiri::HTML5.fragment(Views::Assessments::TeamBlades.new(capabilities:, label: "Team", medians: true).call)
  end

  def medians(capabilities) = picture(capabilities).css("[data-blade-median]").map { |line| line["data-blade-median"] }

  def radius(path) = path["d"].scan(/A(\d+(?:\.\d+)?)/).first.first.to_f

  should "draw a line for a group score of 0, and none where there is no group score" do
    lines = medians([ capability("a", score: 80, group_median: 0), capability("b", score: 80, group_median: nil),
                      capability("c", score: 80, group_median: 90) ])

    assert_equal %w[1 3], lines
  end

  should "draw a small group score where a team blade of the same score ends" do
    drawn = picture([ capability("a", score: 3, group_median: 3) ])

    assert_equal radius(drawn.at_css("[data-blade='1']")), radius(drawn.at_css("[data-blade-median='1']"))
  end
end
