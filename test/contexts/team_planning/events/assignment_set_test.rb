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
end
