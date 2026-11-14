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

  should "say which unit a succession lost, and nothing for one whose predecessor retired as it should" do
    fits = B::Succession.new(id: SecureRandom.uuid_v7, predecessor_ids: [ RETIRED ], successor_ids: [ LIVE ])
    broken = B::Succession.new(id: SecureRandom.uuid_v7, predecessor_ids: [ GONE ], successor_ids: [ RETIRED ])

    assert_empty reasons(map(successions: [ fits ]))
    assert_equal [ "It carries on from a unit no longer in this scenario", "It is carried on by a retired unit" ],
                 reasons(map(successions: [ broken ]))
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

  should "read why someone off the map can't be placed" do
    assert_equal [ "Placed, but has left" ], reasons(map(unresolved: [ B::Unresolved.new(person_id: PERSON, why: B::Unresolved::LEFT) ]))
  end
end
