# frozen_string_literal: true

require "test_helper"

# The team's blades, with a line across each at the group's score.
class Views::Assessments::TeamBladesTest < ActiveSupport::TestCase
  def capability(stable_id, score:, group_median:)
    { stable_id:, name: stable_id, category_id: "cat", category_name: "Craft", hue: Assessments::CapabilityShape::HUES.first, score:, scored: 2, short: 0,
      group_median: }
  end

  def medians(capabilities)
    html = Views::Assessments::TeamBlades.new(capabilities:, label: "Team", medians: true).call
    Nokogiri::HTML5.fragment(html).css("[data-blade-median]").map { |line| line["data-blade-median"] }
  end

  should "draw a line for a group score of 0, and none where there is no group score" do
    lines = medians([ capability("a", score: 80, group_median: 0), capability("b", score: 80, group_median: nil),
                      capability("c", score: 80, group_median: 90) ])

    assert_equal %w[1 3], lines
  end
end
