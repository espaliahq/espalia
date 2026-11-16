# frozen_string_literal: true

require "test_helper"

class Views::Plans::ScenarioMapTest < ActiveSupport::TestCase
  PLAN = "01a1da48-c64a-7529-af90-0f97e41cda99"
  PAYMENTS = "01a1da48-c64a-7529-af90-0f97e41cdaa0"
  POSITION = "01a1da48-c64a-7529-af90-0f97e41cdaa1"
  ADA = "01a1da48-c64a-7529-af90-0f97e41cdaa2"

  def render_map(people: [], positions: [], units: [ unit(PAYMENTS, "Payments") ])
    map = { plan_id: PLAN, scenario_id: PLAN, base_on: "2026-11-15", known_on: "2026-11-14", units:, people:,
            unassigned_ids: [], positions:, unresolved: [], names: { ADA => "Ada Quill" } }
    scenarios = [ { scenario_id: PLAN, parent_id: nil, name: "Pay review" } ]
    Nokogiri::HTML5.fragment(render_view(Views::Plans::ScenarioMap.new(map:, scenarios:)))
  end

  def render_view(view)
    controller = ApplicationController.new
    controller.request = ActionDispatch::TestRequest.create
    controller.view_context.render(view)
  end

  def unit(id, name, parent_id: nil) = { id:, name:, parent_id:, level_id: nil, owner_ids: [] }

  def place(unit_id, allocation, role: "ENG", position_id: nil) = { unit_id:, allocation:, role:, position_id: }

  def position(open_fte, unit_id: PAYMENTS) = { position_id: POSITION, unit_id:, basis: "new", role_name: "Software Engineer", level_name: nil, open_fte: }

  def card(html, name) = html.css("[data-map-unit]").find { it.at_css("h3").text == name }

  context "a unit card" do
    should "count a person with two places in the unit once" do
      ada = { id: ADA, fte: 1.0, memberships: [ place(PAYMENTS, 0.5), place(PAYMENTS, 0.5, position_id: POSITION) ] }
      summary = card(render_map(people: [ ada ], positions: [ position(0.5) ]), "Payments").at_css("header p:last-child").text

      assert_equal "1 person · 1.0 FTE", summary
    end

    should "say how far an overfilled position is over" do
      assert_includes card(render_map(positions: [ position(-1.0) ]), "Payments").text, "1.0 FTE over"
    end

    should "keep its positions out of the description list" do
      ada = { id: ADA, fte: 1.0, memberships: [ place(PAYMENTS, 1.0) ] }
      payments = card(render_map(people: [ ada ], positions: [ position(1.0) ]), "Payments")

      assert payments.at_css("dl").css("> *").all? { it.name == "div" && it.at_css("> dt") && it.at_css("> dd") }
      assert payments.at_css("[data-map-position]")
    end

    should "carry a clamped role label's full text on hover" do
      ada = { id: ADA, fte: 1.0, memberships: [ place(PAYMENTS, 1.0, role: "Infrastructure reliability") ] }

      assert_equal "Infrastructure reliability", card(render_map(people: [ ada ]), "Payments").at_css("dt")["title"]
    end
  end

  should "name who fills each position under that position" do
    grace = "01a1da48-c64a-7529-af90-0f97e41cdaa5"
    second = "01a1da48-c64a-7529-af90-0f97e41cdaa6"
    positions = [ position(0.5).merge(occupants: [ { person_id: ADA, allocation: 0.5, role: "ENG" } ]),
                  position(0.0).merge(position_id: second, occupants: [ { person_id: grace, allocation: 1.0, role: "ENG" } ]) ]
    rows = render_map(positions:).css("[data-map-position]").to_h { [ it["data-map-position"], it.text ] }

    assert_includes rows[POSITION], "Ada Quill · 50%"
    assert_not_includes rows[POSITION], "100%"
    assert_includes rows[second], "#{Person::FORMER_MEMBER} · 100%"
    assert_not_includes rows[second], "Ada Quill"
  end

  context "the units" do
    should "still show units whose parents loop" do
      growth = "01a1da48-c64a-7529-af90-0f97e41cdaa4"
      html = render_map(units: [ unit(PAYMENTS, "Payments", parent_id: growth), unit(growth, "Growth", parent_id: PAYMENTS) ])

      assert_equal %w[Growth Payments], html.css("[data-map-unit] h3").map(&:text)
    end
  end

  context "the Unassigned card" do
    should "list a position whose unit isn't on the map" do
      gone = "01a1da48-c64a-7529-af90-0f97e41cdaa3"
      unassigned = card(render_map(positions: [ position(1.0, unit_id: gone) ]), "Unassigned")

      assert_equal "1 position in no unit", unassigned.at_css("header p").text
      assert_includes unassigned.at_css("[data-map-position]").text, "New position: Software Engineer"
    end
  end

  should "number positions that read alike oldest first, wherever the map lists them" do
    older, newer = [ "01a1da48-c64a-7529-af90-0f97e41cdab1", "01a1da48-c64a-7529-af90-0f97e41cdab2" ]
    alike = [ newer, older ].map { position(1).merge(position_id: it, level_id: "e2") }
    names = Views::Plans::ScenarioMap.position_names(alike + [ position(1).merge(level_id: "e3") ])

    assert_equal({ older => "New position: Software Engineer (1)", newer => "New position: Software Engineer (2)",
                   POSITION => "New position: Software Engineer" }, names)
  end

  should "offer to move a place the HRIS gave no allocation with the share its time outside a scoped plan leaves" do
    step = "01a1da48-c64a-7529-af90-0f97e41cdaa3"
    ada = { id: ADA, memberships: [ place(PAYMENTS, nil) ], outside: { share: 0.25 }, manager_id: nil, manager_outside: false,
            leaving: false, planned_level: nil, plan_data: {}, capacity_overrides: {}, placeholder: nil, allocation_total: 0.75 }
    map = { plan_id: PLAN, scenario_id: step, base_on: "2026-11-15", known_on: "2026-11-14", units: [ unit(PAYMENTS, "Payments") ],
            people: [ ada ], unassigned_ids: [], positions: [], unresolved: [], names: { ADA => "Ada Quill" } }
    scenarios = [ { scenario_id: PLAN, parent_id: nil, name: "Pay review" }, { scenario_id: step, parent_id: PLAN, name: "Q1" } ]
    html = Nokogiri::HTML5.fragment(render_view(Views::Plans::ScenarioMap.new(map:, scenarios:, can_edit: true)))

    assert_equal [ "75" ], html.css("[data-move-allocation]").map { it["data-move-allocation"] }
  end
end
