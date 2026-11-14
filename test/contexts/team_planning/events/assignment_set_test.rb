# frozen_string_literal: true

require "test_helper"

class TeamPlanning::Events::AssignmentSetTest < ActiveSupport::TestCase
  UNIT = "0190A1B2-0000-7000-8000-000000000003"

  def end_state(*placements) = TeamPlanning::Events::AssignmentSet.end_state({ placements: })

  should "store ids downcased, allocations as numbers and a blank role as none" do
    assert_equal({ placements: [ { position_id: nil, unit_id: UNIT.downcase, allocation: 0.5, role: nil } ] },
                 end_state({ "unit_id" => " #{UNIT} ", "allocation" => "0.5", "role" => " " }))
    assert_equal({ placements: [] }, end_state)
  end

  should "refuse a list that isn't one, and a placement that isn't a hash" do
    assert_raises(TeamPlanning::Error) { TeamPlanning::Events::AssignmentSet.end_state({ placements: "Payments" }) }
    assert_raises(TeamPlanning::Error) { end_state("Payments") }
  end

  should "skip a person the map doesn't have, listing them as unresolved, and an empty list for them as nothing" do
    map = TeamPlanning::Baseline::Map.new(base_on: Date.current, known_on: Date.current, units: [], people: [], unassigned_ids: [],
                                          positions: [], names: {}, rules: nil)
    placed = TeamPlanning::Events::AssignmentSet.apply_to(map, { subject_id: "p1", placements: [ { unit_id: "u", allocation: 1.0 } ] })

    assert_equal [ TeamPlanning::Baseline::Unresolved.new(person_id: "p1", why: nil) ], placed.unresolved
    assert_equal map, TeamPlanning::Events::AssignmentSet.apply_to(map, { subject_id: "p1", placements: [] })
  end

  should "read a person's placements back as the end state that set them, and nothing for someone the map hasn't" do
    person = TeamPlanning::Baseline::Member.new(id: "p1", title: nil, level: nil, manager_id: nil, cost_centre: nil, site: nil, country: nil,
                                                fte: nil, employment_type: nil, memberships: [])
    map = TeamPlanning::Baseline::Map.new(base_on: Date.current, known_on: Date.current, units: [], people: [ person ], unassigned_ids: [],
                                          positions: [], names: {}, rules: nil)
    state = end_state({ unit_id: "0190a1b2-0000-7000-8000-000000000009", allocation: 0.5 }, { unit_id: UNIT, allocation: 0.5, role: "Lead" })
    placed = TeamPlanning::Events::AssignmentSet.apply_to(map, { subject_id: "p1", **state })

    assert_equal state, TeamPlanning::Events::AssignmentSet.read_from(placed, subject_id: "p1")
    assert_nil TeamPlanning::Events::AssignmentSet.read_from(map, subject_id: "p2")
  end

  should "hold two placement lists in another order the same, and a different allocation not" do
    one = { unit_id: UNIT.downcase, allocation: 0.5, role: nil, position_id: nil }
    two = { unit_id: "0190a1b2-0000-7000-8000-000000000009", allocation: 0.5, role: nil, position_id: nil }

    assert TeamPlanning::Events::AssignmentSet.same_end_state?({ placements: [ one, two ] }, { "placements" => [ two, one ] })
    assert_not TeamPlanning::Events::AssignmentSet.same_end_state?({ placements: [ one, two ] }, { placements: [ one, two.merge(allocation: 1.0) ] })
    assert_not TeamPlanning::Events::AssignmentSet.same_end_state?(nil, { placements: [] })
  end
end
