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

  should "know the baseline from its id, which is the plan's" do
    assert marks(payload(PLAN, "1", [])).baseline?
    assert_not marks(payload(SCENARIO, "1", [])).baseline?
  end
end
