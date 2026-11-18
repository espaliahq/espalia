# frozen_string_literal: true

require "test_helper"

# The team card at the head of Team Assessments: the team's blades, how many
# capabilities it meets, and its common gaps, or a blank slate until two
# people in view have a score.
class Views::Assessments::TeamCardTest < ActiveSupport::TestCase
  def payload(**overrides)
    { people: "direct", indirect_reports: false, ratings: "manager",
      role: { id: "role-e", name: "Software Engineer" }, roles: [ { id: "role-e", name: "Software Engineer", people: 10 } ],
      level_ordinal: nil, levels: [], in_view: 10, scored: 8, met: 1,
      capabilities: [
        { stable_id: "cap-a", name: "Critical thinking", category_id: "cat-t", category_name: "Thinking", hue: 1,
          score: 120, scored: 8, short: 2 },
        { stable_id: "cap-b", name: "Player coach", category_id: "cat-c", category_name: "Coaching", hue: 3,
          score: 60, scored: 8, short: 6 },
        { stable_id: "cap-c", name: "Mentoring", category_id: "cat-c", category_name: "Coaching", hue: 3,
          score: nil, scored: 0, short: 0 }
      ],
      gaps: [ { stable_id: "cap-b", name: "Player coach", short: 6, scored: 8 } ] }.merge(overrides)
  end

  def render_card(data = payload)
    Nokogiri::HTML5.fragment(view_context.render(Views::Assessments::TeamCard.new(team: data)))
  end

  def view_context
    @view_context ||= ApplicationController.new.tap do |controller|
      controller.request = ActionDispatch::TestRequest.create
    end.view_context
  end

  should "name the team, its role and the ratings it reads" do
    card = render_card

    assert_includes card.text, "Your team’s shape"
    assert_includes card.text, "10 direct reports · Software Engineer · manager ratings"
  end

  should "count the capabilities met as a team and list each common gap with its count" do
    card = render_card

    assert_includes card.text, "1 of 3 capabilities met as a team"
    assert_equal [ "Player coach · 6 of 8 short" ], card.css("[data-team-gap]").map { |chip| chip.text.squish }
  end

  should "draw a blade per scored capability, as long as the team's score, and hold a slot for the rest" do
    card = render_card
    blades = card.css("[data-team-blades] [data-blade]")

    assert_equal %w[1 2], blades.map { |b| b["data-blade"] }
    assert card.at_css("[data-blade='2']").key?("data-blade-short")
    assert card.at_css("[data-blade-beyond='1']"), "a blade past met sticks out beyond the dashed circle"
    assert card.at_css("[data-team-blades] [data-blades-met]")
  end

  should "switch between direct reports and everyone below, only for a manager of managers" do
    switch = render_card(payload(indirect_reports: true)).at_css("[aria-label='Who is in the team']")

    assert_equal [ [ "Direct reports", "page" ], [ "Everyone below you", nil ] ],
                 switch.css("a").map { |a| [ a.text, a["aria-current"] ] }
    assert_includes switch.css("a").last["href"], "team_people=below"
    assert_nil render_card.at_css("[aria-label='Who is in the team']")
  end

  should "carry the card's choices in each link's query string, back to the card" do
    roles = [ { id: "role-e", name: "Software Engineer", people: 7 }, { id: "role-d", name: "Product Designer", people: 3 } ]
    card = render_card(payload(indirect_reports: true, roles:))
    below = URI.parse(card.at_css("[aria-label='Who is in the team'] a:last-child")["href"])
    designer = URI.parse(card.css("[data-team-roles] [role='menuitem']").last["href"])

    assert_equal [ "/assessments", "team-card" ], [ below.path, below.fragment ]
    assert_equal({ "team_people" => "below", "team_role" => "role-e" }, Rack::Utils.parse_query(below.query))
    assert_equal({ "team_role" => "role-d" }, Rack::Utils.parse_query(designer.query))
  end

  should "keep the switch on the blank slate, so widening can give enough people" do
    assert render_card(payload(scored: 0, indirect_reports: true)).at_css("[aria-label='Who is in the team']")
  end

  should "offer a role menu when the team holds more than one role, naming the role shown" do
    roles = [ { id: "role-e", name: "Software Engineer", people: 7 }, { id: "role-d", name: "Product Designer", people: 3 } ]
    card = render_card(payload(roles:))
    menu = card.at_css("[data-team-roles]")

    assert_includes menu.at_css("[aria-haspopup]").text, "Software Engineer"
    assert_equal [ "Software Engineer · 7", "Product Designer · 3" ], menu.css("[role='menuitem']").map { |i| i.text.squish }
    assert_includes menu.css("[role='menuitem']").last["href"], "team_role=role-d"
    assert_nil render_card.at_css("[data-team-roles]")
  end

  should "open the team map with the card's choices, but not from the blank slate" do
    card = render_card(payload(people: "below", indirect_reports: true))

    assert_equal "Open team map", card.at_css("[data-action='modal#open']").text.squish
    assert_includes card.at_css("turbo-frame#team-map")["src"], "team_people=below"
    assert_nil render_card(payload(scored: 1)).at_css("turbo-frame#team-map")
  end

  should "say nobody is in an open cycle yet, rather than counting nothing" do
    card = render_card(payload(in_view: 0, scored: 0, role: nil, roles: []))

    assert_includes card.text.squish, "None of your reports is in an open assessment cycle yet."
    assert_not_includes card.text, "0 of 0"
  end

  should "never name anyone on the team" do
    assert_no_match(/Ada|Bo /, render_card.text)
  end

  should "show a blank slate with how many have a score until two do" do
    card = render_card(payload(scored: 1))

    assert_includes card.text.squish, "Shows once at least two of your reports have a score. 1 of 10 has one so far."
    assert_empty card.css("[data-blade]")
    assert card.at_css("[data-team-blank]")
  end
end
