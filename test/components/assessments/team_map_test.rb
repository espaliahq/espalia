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

  should "carry a comparison turned off into its links" do
    below = render_map(payload(compare: "none")).at_css("[aria-label='Who is in the team'] a:last-child")

    assert_includes below["href"], "team_compare=none"
  end
end
