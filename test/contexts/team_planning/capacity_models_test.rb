# frozen_string_literal: true

require "test_helper"

class TeamPlanning::CapacityModelsTest < ActiveSupport::TestCase
  Model = TeamPlanning::CapacityModel

  def model(name)
    Class.new(Model) do
      define_singleton_method(:model_name) { name }
      define_singleton_method(:description) { "A test model" }
    end
  end

  should "hold every built-in model once, each described" do
    assert_equal TeamPlanning::CapacityModels::BUILT_IN.uniq, TeamPlanning::CapacityModels::BUILT_IN
    TeamPlanning::CapacityModels::BUILT_IN.map(&:constantize).each { assert_kind_of String, it.description }
    assert_equal TeamPlanning::CapacityModels::PerFte, TeamPlanning::CapacityModels.fetch("per_fte")
  end

  should "hold a registered model until it is unregistered" do
    test_model = model("test_cases")
    TeamPlanning::CapacityModels.register(test_model)

    assert_equal test_model, TeamPlanning::CapacityModels.fetch("test_cases")
    assert TeamPlanning::CapacityModels.registered?("test_cases")
  ensure
    TeamPlanning::CapacityModels.unregister(test_model)
    assert_not TeamPlanning::CapacityModels.registered?("test_cases")
    assert_raises(TeamPlanning::Error) { TeamPlanning::CapacityModels.fetch("test_cases") }
  end

  should "refuse a second model with a name another holds, a name that isn't snake_case, and a class that isn't a model" do
    assert_match "already holds", assert_raises(ArgumentError) { TeamPlanning::CapacityModels.register(model("per_fte")) }.message
    assert_raises(ArgumentError) { TeamPlanning::CapacityModels.register(model("Per FTE")) }
    assert_raises(ArgumentError) { TeamPlanning::CapacityModels.register(String) }
    assert_equal TeamPlanning::CapacityModels::PerFte, TeamPlanning::CapacityModels.fetch("per_fte")
  end

  should "refuse params per_fte doesn't take, naming the key and never its value" do
    error = assert_raises(TeamPlanning::Error) { TeamPlanning::CapacityModels.check("per_fte", { curve: "secret-1.7" }) }

    assert_match "curve", error.message
    assert_no_match "secret", error.message
    assert_raises(TeamPlanning::Error) { TeamPlanning::CapacityModels.check("per_fte", "flat") }
    assert_equal({}, TeamPlanning::CapacityModels.check("per_fte", {}))
  end

  should "price a place at one unit per FTE, exactly, scaled by its share of the seat" do
    place = Model::Place.new(unit_id: "u1", allocation: Rational("0.6"), allocation_known: true, role_id: "r", level_id: nil, position_id: nil)
    seat = Model::Seat.new(id: "p1", kind: "person", fte: Rational("0.5"), fte_known: true, places: [ place ])

    figure = TeamPlanning::CapacityModels::PerFte.capacity_of(seat, place:, params: {}, map: nil)

    assert_equal Rational(3, 10), figure.amount
    assert_equal [ Rational(1, 2), Rational(3, 5), Rational(3, 10) ], figure.working.map(&:amount)
    assert_equal "FTE", figure.working.first.label
  end

  should "say in the working when an FTE wasn't recorded" do
    place = Model::Place.new(unit_id: nil, allocation: 1r, allocation_known: true, role_id: "r", level_id: nil, position_id: nil)
    seat = Model::Seat.new(id: "p1", kind: "person", fte: 1r, fte_known: false, places: [ place ])

    assert_equal "FTE not recorded, counted as 1", TeamPlanning::CapacityModels::PerFte.capacity_of(seat, place:, params: {}, map: nil).working.first.label
  end
end
