# frozen_string_literal: true

require "test_helper"

class TeamPlanning::AttentionTest < ActiveSupport::TestCase
  B = TeamPlanning::Baseline
  LEVEL, ROOT, LIVE, RETIRED, GONE, PERSON = Array.new(6) { SecureRandom.uuid_v7 }

  def map(**overrides)
    B::Map.new(base_on: Date.new(2027, 1, 1), known_on: Date.new(2027, 1, 1), units: [ unit(ROOT, nil), unit(LIVE, ROOT) ],
               retired_units: [ unit(RETIRED, ROOT) ], people: [], unassigned_ids: [], positions: [], names: {}, rules: nil,
               **overrides)
  end

  def unit(id, parent_id) = B::Unit.new(id:, name: "Unit", parent_id:, level_id: LEVEL, owner_ids: [])

  def change(kind, subject_id, **end_state) = kind.new(data: { plan_id: ROOT, scenario_id: ROOT, subject_id:, set_by_id: PERSON, **end_state })

  def reasons(map, changes = {}) = TeamPlanning::Attention.new(map, changes).call.map(&:reason)

  should "mark a place that counts for no capacity, but not a leaver's, a forgotten override's or a closed position's" do
    position = SecureRandom.uuid_v7
    unclassified = { "no_model" => nil, "leaving" => nil, "override_unknown" => nil, "closed_position" => position }.map do |reason, position_id|
      place = TeamPlanning::CapacityModel::Place.new(unit_id: LIVE, allocation: 1r, allocation_known: true, role_id: nil, level_id: nil, position_id:)
      seat = TeamPlanning::CapacityModel::Seat.new(id: PERSON, kind: "person", fte: 1r, fte_known: true, places: [ place ])
      [ TeamPlanning::Capacity::Seat.new(seat:, places: []),
        TeamPlanning::Capacity::Place.new(place:, model: nil, chosen_for: nil, figure: nil, reason:) ]
    end

    items = TeamPlanning::Attention.new(map, {}, unclassified:).call
    assert_equal [ [ PERSON, "capacity:#{LIVE}", "Counts for no capacity: no capacity model is chosen for the role or its family" ] ],
                 items.map { [ it.subject_id, it.facet, it.reason ] }
  end

  should "name a place in no unit as unassigned, so every capacity facet has a place" do
    place = TeamPlanning::CapacityModel::Place.new(unit_id: nil, allocation: 1r, allocation_known: true, role_id: nil, level_id: nil, position_id: nil)
    seat = TeamPlanning::CapacityModel::Seat.new(id: PERSON, kind: "person", fte: 1r, fte_known: true, places: [ place ])
    unclassified = [ [ TeamPlanning::Capacity::Seat.new(seat:, places: []),
                       TeamPlanning::Capacity::Place.new(place:, model: nil, chosen_for: nil, figure: nil, reason: "no_model") ] ]

    assert_equal [ "capacity:unassigned" ], TeamPlanning::Attention.new(map, {}, unclassified:).call.map(&:facet)
  end

  should "credit the level change that left a place with no level, when it lands after the placement" do
    place = TeamPlanning::CapacityModel::Place.new(unit_id: LIVE, allocation: 1r, allocation_known: true, role_id: nil, level_id: nil, position_id: nil)
    seat = TeamPlanning::CapacityModel::Seat.new(id: PERSON, kind: "person", fte: 1r, fte_known: true, places: [ place ])
    unclassified = [ [ TeamPlanning::Capacity::Seat.new(seat:, places: []),
                       TeamPlanning::Capacity::Place.new(place:, model: nil, chosen_for: nil, figure: nil, reason: "no_level") ] ]
    placed = change(TeamPlanning::Events::AssignmentSet, PERSON)
    levelled = change(TeamPlanning::Events::LevelSet, PERSON)
    changes = { [ PERSON, TeamPlanning::Attention::ASSIGNMENT ] => placed, [ PERSON, TeamPlanning::Attention::LEVEL ] => levelled }

    assert_same levelled, TeamPlanning::Attention.new(map, changes, unclassified:).call.sole.change
  end

  should "say which unit a succession lost, and nothing for one whose predecessor retired as it should" do
    fits = B::Succession.new(id: SecureRandom.uuid_v7, predecessor_ids: [ RETIRED ], successor_ids: [ LIVE ])
    broken = B::Succession.new(id: SecureRandom.uuid_v7, predecessor_ids: [ GONE ], successor_ids: [ RETIRED ])

    assert_empty reasons(map(successions: [ fits ]))
    assert_equal [ "It carries on from a unit no longer in this scenario", "It is carried on by a retired unit" ],
                 reasons(map(successions: [ broken ]))
  end

  should "mark a succession whose predecessor is live again" do
    assert_equal [ "It carries on from a unit that is still live" ],
                 reasons(map(successions: [ B::Succession.new(id: SecureRandom.uuid_v7, predecessor_ids: [ LIVE ], successor_ids: [ ROOT ]) ]))
  end

  should "mark someone once for each reason, however many of their places it covers" do
    places = [ RETIRED, RETIRED ].map { B::Membership.new(unit_id: it, allocation: 0.5, role: nil) }
    person = B::Member.new(id: PERSON, title: nil, level: nil, manager_id: nil, cost_centre: nil, site: nil, country: nil, fte: 1,
                           employment_type: nil, memberships: places + [ B::Membership.new(unit_id: GONE, allocation: 0.5, role: nil) ])

    assert_equal [ "Placed in a retired unit", "Placed in a unit no longer in this scenario" ], reasons(map(people: [ person ]))
  end

  should "tell a retired unit from one no longer in the scenario" do
    units = [ unit(ROOT, nil), unit(LIVE, GONE) ]
    person = B::Member.new(id: PERSON, title: nil, level: nil, manager_id: nil, cost_centre: nil, site: nil, country: nil, fte: 1,
                           employment_type: nil, memberships: [ B::Membership.new(unit_id: GONE, allocation: 1, role: nil) ])

    assert_equal [ "Placed in a unit no longer in this scenario", "Its parent is a unit no longer in this scenario" ],
                 reasons(map(units:, people: [ person ]))
  end

  should "name the change that broke a subject no scenario changed, and none when nothing explains it" do
    retired = change(TeamPlanning::Events::UnitRetired, RETIRED, name: "Unit", parent_id: ROOT, level_id: LEVEL)
    orphan = unit(SecureRandom.uuid_v7, RETIRED)

    assert_equal [ retired ], TeamPlanning::Attention.new(map(units: [ unit(ROOT, nil), orphan ]), { retired.key => retired }).call.map(&:change)
    assert_equal [ nil ], TeamPlanning::Attention.new(map(units: [ unit(ROOT, nil), orphan ]), {}).call.map(&:change)
  end

  should "name the later of two retirements behind one reason" do
    other = SecureRandom.uuid_v7
    first, last = [ RETIRED, other ].map { change(TeamPlanning::Events::UnitRetired, it, name: "Unit", parent_id: ROOT, level_id: LEVEL) }
    changes = { first.key => first, last.key => last }
    person = B::Member.new(id: PERSON, title: nil, level: nil, manager_id: nil, cost_centre: nil, site: nil, country: nil, fte: 1,
                           employment_type: nil,
                           memberships: [ RETIRED, other ].map { B::Membership.new(unit_id: it, allocation: 0.5, role: nil) })
    succession = B::Succession.new(id: SecureRandom.uuid_v7, predecessor_ids: [], successor_ids: [ RETIRED, other ])
    retired_units = [ unit(RETIRED, ROOT), unit(other, ROOT) ]

    assert_equal [ last, last ],
                 TeamPlanning::Attention.new(map(retired_units:, people: [ person ], successions: [ succession ]), changes).call.map(&:change)
  end

  should "read a small overfill at the precision open FTE keeps" do
    position = B::Position.new(id: SecureRandom.uuid_v7, role_id: nil, level_id: LEVEL, unit_id: LIVE, fte: 1.0, basis: "new",
                               role_name: nil, level_name: nil)
    person = B::Member.new(id: PERSON, title: nil, level: nil, manager_id: nil, cost_centre: nil, site: nil, country: nil, fte: 1,
                           employment_type: nil,
                           memberships: [ B::Membership.new(unit_id: LIVE, allocation: 1.004, role: nil, position_id: position.id) ])

    assert_equal [ "Overfilled by 0.004 FTE" ], reasons(map(positions: [ position ], people: [ person ]))
  end

  should "read why someone off the map can't be placed" do
    assert_equal [ "Placed, but has left" ], reasons(map(unresolved: [ B::Unresolved.new(person_id: PERSON, why: B::Unresolved::LEFT) ]))
  end
end
