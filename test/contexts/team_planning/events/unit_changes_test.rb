# frozen_string_literal: true

require "test_helper"

class TeamPlanning::Events::UnitChangesTest < ActiveSupport::TestCase
  UNIT = TeamPlanning::Baseline::Unit
  LEVEL, PARENT, OTHER = Array.new(3) { SecureRandom.uuid_v7 }

  def map(units: [], retired: [], org_unit_levels: {})
    TeamPlanning::Baseline::Map.new(base_on: Date.new(2027, 1, 1), known_on: Date.new(2027, 1, 1), units:,
                                    retired_units: retired, successions: [], people: [], unassigned_ids: [], positions: [], names: {},
                                    rules: nil, org_unit_levels:)
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

    should "take the Org Graph's type for a unit it holds, live or retired, and keep the plan's own for a unit it created" do
      held, retired, created = Array.new(3) { SecureRandom.uuid_v7 }
      retyped = map(units: [ unit(held) ], org_unit_levels: { held => OTHER, retired => OTHER })
      [ held, retired ].each do |id|
        set = TeamPlanning::Events::UnitSet.apply_to(retyped, subject_id: id, name: "Billing", parent_id: nil, level_id: LEVEL)
        assert_equal OTHER, set.units.find { it.id == id }.level_id
      end
      set = TeamPlanning::Events::UnitSet.apply_to(retyped, subject_id: created, name: "Risk", parent_id: nil, level_id: LEVEL)
      assert_equal LEVEL, set.units.find { it.id == created }.level_id
    end

    should "show a unit the Org Graph holds whatever type a plan's change carries, and compare the type of one only the plan holds" do
      state = { name: "Billing", parent_id: PARENT, level_id: LEVEL }
      assert TeamPlanning::Events::UnitSet.shows?(state.merge(level_id: OTHER), state, map:)
      assert_not TeamPlanning::Events::UnitSet.shows?(state.merge(name: "Ledger", level_id: OTHER), state, map:)
      assert_not TeamPlanning::Events::UnitSet.shows?(nil, state, map:)
      assert TeamPlanning::Events::UnitSet.shows?(nil, nil, map:)
    end

    should "read a live unit back as the end state that set it, and nothing for a retired one" do
      id = SecureRandom.uuid_v7
      state = { name: "Billing", parent_id: PARENT, level_id: LEVEL }
      set = TeamPlanning::Events::UnitSet.apply_to(map, subject_id: id, **state)
      assert_equal state, TeamPlanning::Events::UnitSet.read_from(set, subject_id: id)
      assert_nil TeamPlanning::Events::UnitSet.read_from(map(retired: [ unit(id) ]), subject_id: id)
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

    should "read a retired unit back as it stood, and nothing for a live one" do
      id = SecureRandom.uuid_v7
      retired = TeamPlanning::Events::UnitRetired.apply_to(map, subject_id: id, name: "Billing", parent_id: nil, level_id: LEVEL)
      assert_equal({ name: "Billing", parent_id: nil, level_id: LEVEL },
                   TeamPlanning::Events::UnitRetired.read_from(retired, subject_id: id))
      assert_nil TeamPlanning::Events::UnitRetired.read_from(map(units: [ unit(id) ]), subject_id: id)
    end

    should "leave the unit facet to both kinds, retirement first" do
      assert_equal [ TeamPlanning::Events::UnitRetired, TeamPlanning::Events::UnitSet ], TeamPlanning::ChangeKinds.holding("unit")
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

    should "read a succession back as the end state that set it" do
      id = SecureRandom.uuid_v7
      state = { predecessor_ids: [ LEVEL ], successor_ids: [ PARENT ] }
      set = TeamPlanning::Events::UnitSuccessionSet.apply_to(map, subject_id: id, **state)
      assert_equal state, TeamPlanning::Events::UnitSuccessionSet.read_from(set, subject_id: id)
      assert_nil TeamPlanning::Events::UnitSuccessionSet.read_from(map, subject_id: SecureRandom.uuid_v7)
    end
  end
end
