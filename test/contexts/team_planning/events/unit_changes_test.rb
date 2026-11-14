# frozen_string_literal: true

require "test_helper"

class TeamPlanning::Events::UnitChangesTest < ActiveSupport::TestCase
  UNIT = TeamPlanning::Baseline::Unit
  LEVEL, PARENT, OTHER = Array.new(3) { SecureRandom.uuid_v7 }

  def map(units: [], retired: [])
    TeamPlanning::Baseline::Map.new(base_on: Date.new(2027, 1, 1), known_on: Date.new(2027, 1, 1), units:,
                                    retired_units: retired, successions: [], people: [], unassigned_ids: [], names: {}, rules: nil)
  end

  def unit(id, name = "Payments") = UNIT.new(id:, name:, parent_id: PARENT, level_id: LEVEL, owner_ids: [ OTHER ])

  context "UnitSet" do
    should "keep a whole end state, squished and with ids downcased" do
      assert_equal({ name: "Risk and Fraud", parent_id: PARENT, level_id: LEVEL },
                   TeamPlanning::Events::UnitSet.end_state(name: " Risk  and Fraud ", parent_id: PARENT.upcase, level_id: LEVEL))
      assert_nil TeamPlanning::Events::UnitSet.end_state(name: "Risk", parent_id: "", level_id: LEVEL)[:parent_id]
    end

    should "refuse a missing name or level, a name past the limit and an id that isn't one" do
      { "A unit needs a level" => { name: "Risk" },
        "The parent must be an id" => { name: "Risk", level_id: LEVEL, parent_id: "payments" } }.each do |message, state|
        assert_equal message, assert_raises(TeamPlanning::Error) { TeamPlanning::Events::UnitSet.end_state(state) }.message
      end
      assert_raises(TeamPlanning::Error) { TeamPlanning::Events::UnitSet.end_state(name: " ", level_id: LEVEL) }
      assert_raises(TeamPlanning::Error) { TeamPlanning::Events::UnitSet.end_state(name: "x" * 121, level_id: LEVEL) }
    end

    should "replace a unit in place, keeping its owners, and bring a retired one back" do
      id = SecureRandom.uuid_v7
      renamed = TeamPlanning::Events::UnitSet.apply_to(map(retired: [ unit(id) ]), subject_id: id, name: "Billing",
                                                                                   parent_id: nil, level_id: LEVEL)
      assert_equal [ [ "Billing", nil, [ OTHER ] ] ], renamed.units.map { [ it.name, it.parent_id, it.owner_ids ] }
      assert_empty renamed.retired_units
    end
  end

  context "UnitRetired" do
    should "share the unit facet, so the later of a set and a retirement wins" do
      assert_equal TeamPlanning::Events::UnitSet.facet, TeamPlanning::Events::UnitRetired.facet
    end

    should "retire the unit as it stood, whether or not the map already holds it" do
      id = SecureRandom.uuid_v7
      as_it_stood = { subject_id: id, name: "Billing", parent_id: nil, level_id: LEVEL }
      retired = TeamPlanning::Events::UnitRetired.apply_to(map(units: [ unit(id) ]), as_it_stood)
      assert_equal [ [], [ [ "Billing", [ OTHER ] ] ] ], [ retired.units, retired.retired_units.map { [ it.name, it.owner_ids ] } ]
      assert_equal retired, TeamPlanning::Events::UnitRetired.apply_to(retired, as_it_stood)
      assert_equal [ "Billing" ], TeamPlanning::Events::UnitRetired.apply_to(map, as_it_stood).retired_units.map(&:name)
    end
  end

  context "UnitSuccessionSet" do
    should "keep sorted, distinct ids and refuse an empty side or a unit on both" do
      a, b = [ PARENT, OTHER ].sort
      assert_equal({ predecessor_ids: [ LEVEL ], successor_ids: [ a, b ] },
                   TeamPlanning::Events::UnitSuccessionSet.end_state(predecessor_ids: [ LEVEL ], successor_ids: [ b, a, b.upcase ]))
      { "A succession needs at least one successor" => { predecessor_ids: [ LEVEL ], successor_ids: [] },
        "A unit can't succeed itself" => { predecessor_ids: [ LEVEL ], successor_ids: [ LEVEL ] } }.each do |message, state|
        assert_equal message, assert_raises(TeamPlanning::Error) { TeamPlanning::Events::UnitSuccessionSet.end_state(state) }.message
      end
    end
  end
end
