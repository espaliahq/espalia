# frozen_string_literal: true

require "test_helper"

class Views::Plans::CapacityMarksTest < ActiveSupport::TestCase
  PLAN = "01a1da48-c64a-7529-af90-0f97e41cda99"
  SCENARIO = "01a1da48-c64a-7529-af90-0f97e41cdaa9"
  UNITS = %w[01a1da48-c64a-7529-af90-0f97e41cdaa0 01a1da48-c64a-7529-af90-0f97e41cdaa1 01a1da48-c64a-7529-af90-0f97e41cdaa2].freeze
  THIRD = "0.33333333333333333333"
  MODELS = { "units" => { symbol: "u", description: "Units on a curve" } }.freeze

  def payload(scenario_id, total, units)
    { plan_id: PLAN, scenario_id:, totals: { "units" => total }, models: MODELS, seats: [], unclassified: [], names: {},
      units: units.map { |unit_id, amount| { unit_id:, name: "Unit", totals: { "units" => amount } } } }
  end

  def marks(scenario, baseline = payload(PLAN, "1", [])) = Views::Plans::CapacityMarks.new(scenario:, baseline:, names: {})

  should "keep the strip exact until it draws, so three thirds add to the one they came from" do
    scenario = marks(payload(SCENARIO, "1", UNITS.map { [ it, THIRD ] }))

    assert_equal BigDecimal(1), scenario.totals.sole.amount
    assert_empty scenario.outside_units
    assert_equal "0.3u", Views::Plans::CapacityMarks::Format.amount(BigDecimal(THIRD), "u")
  end

  should "count what lies in no unit, so the strip is the units plus the rest" do
    scenario = marks(payload(SCENARIO, "2.5", [ [ UNITS.first, "1.25" ], [ UNITS.second, "0.75" ] ]))
    rest = scenario.outside_units.sole

    assert_equal BigDecimal("0.5"), rest.amount
    assert_equal scenario.totals.sole.amount, BigDecimal("2") + rest.amount
  end

  should "measure the change against the baseline, and say none when it rounds to nothing" do
    format = Views::Plans::CapacityMarks::Format
    change = marks(payload(SCENARIO, "1.5", [])).totals.sole.change

    assert_equal "+0.5u", format.change(change, "u")
    assert_equal "−1.0 FTE", format.change(BigDecimal(-1), "FTE")
    assert_nil format.change(BigDecimal("0.04"), "u")
  end

  should "keep a model and a unit that fall to nothing, so the drop shows" do
    today = payload(PLAN, "2", [ [ UNITS.first, "2" ] ])
    emptied = { plan_id: PLAN, scenario_id: SCENARIO, totals: {}, models: {}, seats: [], unclassified: [], names: {}, units: [] }
    scenario = marks(emptied, today)

    assert scenario.measured?
    assert_equal [ [ BigDecimal(0), BigDecimal(-2), "u" ] ], scenario.totals.map { [ it.amount, it.change, it.unit ] }
    unit = scenario.unit_marks.call({ id: UNITS.first }).sole
    assert_includes unit.call, "(−2.0u vs Today)"
  end

  should "count a place whose model is no longer registered, so its unclassified line shows" do
    gone = { plan_id: PLAN, scenario_id: SCENARIO, totals: {}, models: {}, unclassified: [], names: {}, units: [],
             seats: [ { seat_id: "person-1", places: [ { model: "gone", reason: "unknown_model" } ] } ] }
    nothing = gone.merge(scenario_id: PLAN, seats: [])

    assert marks(gone, nothing).measured?
    assert_not marks(nothing.merge(scenario_id: SCENARIO), nothing).measured?
  end

  should "give an unassigned row the figure for a place left in a retired unit" do
    seat = { seat_id: "person-1", kind: "person", places: [ { unit_id: UNITS.last, position_id: nil, model: "units", capacity: "1",
                                                              overridden: false, calculated: nil, overloaded: false, excess: "0",
                                                              notes: [], working: [] } ] }
    scenario = payload(SCENARIO, "1", []).merge(seats: [ seat ])
    unassigned = ->(live) { Views::Plans::CapacityMarks.new(scenario:, baseline: payload(PLAN, "1", []), names: {}, live_unit_ids: live) }

    assert_includes unassigned.(UNITS.first(2)).person_marks.call({ id: "person-1" }, nil).sole.call, "1.0u"
    assert_empty unassigned.(UNITS).person_marks.call({ id: "person-1" }, nil)
  end

  should "give an unassigned row the figure for a position left in a retired unit" do
    place = { unit_id: UNITS.last, position_id: "position-1", model: "units", capacity: "1", overridden: false, calculated: nil,
              overloaded: false, excess: "0", notes: [], working: [] }
    scenario = payload(SCENARIO, "1", []).merge(seats: [ { seat_id: "person-1", kind: "person", places: [ place ] } ])
    marks = Views::Plans::CapacityMarks.new(scenario:, baseline: payload(PLAN, "1", []), names: {}, live_unit_ids: UNITS.first(2))

    assert_includes marks.person_marks.call({ id: "person-1" }, nil).sole.call, "1.0u"
  end

  should "know the baseline from its id, which is the plan's" do
    assert marks(payload(PLAN, "1", [])).baseline?
    assert_not marks(payload(SCENARIO, "1", [])).baseline?
  end
end
