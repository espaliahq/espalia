# frozen_string_literal: true

require "test_helper"

# The team capability map's controls, drawn from the team operation's payload.
class Views::Assessments::TeamMapTest < ActiveSupport::TestCase
  def payload(**overrides)
    { people: "direct", indirect_reports: true, ratings: "manager", role: nil, roles: [], level_ordinal: nil, levels: [],
      in_view: 0, scored: 0, scored_on_role: 0, met: 0, compare: "level",
      comparison: { shown: false, reason: "none" }, capabilities: [], gaps: [] }.merge(overrides)
  end

  def render_map(data = payload)
    Nokogiri::HTML5.fragment(view_context.render(Views::Assessments::TeamMap.new(team: data)))
  end

  def view_context
    @view_context ||= ApplicationController.new.tap do |controller|
      controller.request = ActionDispatch::TestRequest.create
    end.view_context
  end

  should "keep the default comparison in its links when the team in view has no role" do
    below = render_map.at_css("[aria-label='Who is in the team'] a:last-child")

    assert_includes below["href"], "team_people=below"
    assert_not_includes below["href"], "team_compare"
  end

  should "give each population link a key, so focus returns to it after the map reloads" do
    keys = render_map.css("[aria-label='Who is in the team'] a").map { |a| a["data-refresh-focus"] }

    assert_equal %w[people-direct people-below], keys
  end

  should "spread lane tracks past 200% so a higher score reads apart, with met still halfway" do
    capability = ->(id, score, median) do
      { stable_id: id, name: id, category_id: "cat", category_name: "Thinking", hue: 1, score:, scored: 2, short: 0,
        group_median: median }
    end
    map = render_map(payload(
      role: { id: "role-e", name: "Software Engineer" }, roles: [ { id: "role-e", name: "Software Engineer", people: 2 } ],
      in_view: 2, scored: 2, scored_on_role: 2, met: 2,
      comparison: { shown: true, reason: nil, taken_on: "2026-11-01", min_group_size: 5, group_size: 6, short_levels: [] },
      capabilities: [ capability.call("ahead", 300, 200), capability.call("met", 100, nil) ]
    ))
    ahead = map.at_css("[data-team-lane='ahead']")
    styles = ahead.css("[style]").map { |el| el["style"] }

    assert_includes styles, "width: 100.0%", "expected 300%, the highest, at the end of the track"
    assert_includes styles, "left: 75.0%", "expected the 200% median three quarters along"
    assert_includes map.at_css("[data-team-lane='met']").css("[style]").map { |el| el["style"] }, "width: 50.0%"
  end

  should "carry a comparison turned off into its links" do
    below = render_map(payload(compare: "none")).at_css("[aria-label='Who is in the team'] a:last-child")

    assert_includes below["href"], "team_compare=none"
  end
end
