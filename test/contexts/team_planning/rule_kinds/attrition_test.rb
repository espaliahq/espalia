# frozen_string_literal: true

require "test_helper"

class TeamPlanning::RuleKinds::AttritionTest < ActiveSupport::TestCase
  Map = Struct.new(:rules, :unit_ids) do
    def rule(name, unit_id:) = rules.fetch(name)
    def units = unit_ids.map { Data.define(:id).new(id: it) }
  end

  def check(rule, value) = TeamPlanning::RuleKinds.check(rule, value)

  # One FTE in a unit losing 0.001 FTE a day with 180 days to hire, at a
  # yearly cost of 365 EUR, so a row's cost is minus its empty FTE-days.
  def frame(from, to, earlier: [], unit_ids: [ "platform" ])
    TeamPlanning::Forecast::Frame.new(
      kind: TeamPlanning::RuleKinds::Attrition, step: Date.parse(from)..Date.parse(to), covered: Set.new, earlier:,
      map: Map.new({ "attrition" => { "yearly_rate" => "0.365" }, "time_to_hire" => { "days" => "180" } }, unit_ids),
      filled: [ TeamPlanning::Forecast::Filled.new(person_id: "ada", unit_id: "platform", cost_centre: nil, fte: 1r) ],
      averages: { "platform" => TeamPlanning::Forecast::Average.new(cost: { "EUR" => 365r }, capacity: { "per_fte" => 1r }) }
    )
  end

  def forecast(frame) = TeamPlanning::RuleKinds::Attrition.forecast(frame).sole.then { [ it.headcount, it.cost.fetch("EUR") ] }

  def refusal(rule, value) = assert_raises(TeamPlanning::Error) { check(rule, value) }.message

  should "forecast nothing by default, and keep a backfill out for 90 days" do
    defaults = TeamPlanning::RuleKinds.defaults
    assert_equal 0r, TeamPlanning::RuleKinds::Attrition.yearly_rate(defaults.fetch("attrition"))
    assert_equal 90, TeamPlanning::RuleKinds::TimeToHire.days(defaults.fetch("time_to_hire"))
    assert_includes TeamPlanning::RuleKinds.forecasts, TeamPlanning::RuleKinds::Attrition
    assert_not_includes TeamPlanning::RuleKinds.forecasts, TeamPlanning::RuleKinds::TimeToHire
  end

  should "keep a rate from 0 to 1 as typed" do
    [ "0", "0.12", "1", "1.0", "0.0525" ].each { assert_equal({ "yearly_rate" => it }, check("attrition", { yearly_rate: " #{it} " })) }
  end

  should "refuse a rate outside 0 to 1, or too fine, and any other key" do
    [ "-0.1", "1.2", "12%", "0.12345", "" ].each do |rate|
      assert_equal "yearly_rate must be a share of a year from 0 to 1, such as 0.12", refusal("attrition", { yearly_rate: rate })
    end
    assert_equal "An attrition rule takes only yearly_rate, not unit", refusal("attrition", { yearly_rate: "0.1", unit: "year" })
  end

  should "keep whole days to hire up to two years, and refuse anything else" do
    assert_equal({ "days" => "60" }, check("time_to_hire", { days: "060" }))
    assert_equal({ "days" => "0" }, check("time_to_hire", { days: 0 }))
    [ "731", "-1", "6.5", "soon" ].each do |days|
      assert_equal "days must be whole days from 0 to 730, such as 60", refusal("time_to_hire", { days: })
    end
    assert_equal "A time_to_hire rule takes only days, not weeks", refusal("time_to_hire", { days: "60", weeks: "8" })
  end

  should "count the empty days per FTE leaving a day, whether the time to hire is longer than the step, shorter, or long past" do
    emptied = TeamPlanning::RuleKinds::Attrition.method(:emptied)
    assert_equal 4050r, emptied.(90, 90, 180), "90² / 2: every seat is still empty at the step's end"
    assert_equal 2250r, emptied.(90, 90, 30), "30 × 90 − 30² / 2"
    assert_equal 2700r, emptied.(300, 90, 30), "each of 90 days' leavers empty 30 days, all backfilled"
    assert_equal 0r, emptied.(0, 90, 30)
  end

  # 1 January to 31 March is step 1's 90 days, as in the design doc.
  should "count only the step's own leavers with no earlier step" do
    assert_equal [ Rational(-9, 100), Rational(-405, 100) ], forecast(frame("2026-01-01", "2026-03-31"))
  end

  should "take nothing away for the days between two steps that leave a gap" do
    first = frame("2026-01-01", "2026-03-31")
    # Step 1's leavers are empty 2,700 FTE-days × 0.001 in April, which no step
    # holds; in May to July, 7,650 × 0.001, beside step 2's own 4,050 × 0.001.
    # At 29 July, 60 of step 1's 90 days of leavers are still waiting.
    assert_equal [ Rational(-15, 100), Rational(-117, 10) ], forecast(frame("2026-05-01", "2026-07-29", earlier: [ first ]))
  end

  should "count each empty day once when a later step overlaps an earlier one" do
    first = frame("2026-01-01", "2026-03-31")
    # Step 2 starts on 1 March, but step 1 holds its own days to 31 March, so
    # the carry starts on 1 April: 5,310 × 0.001 beside step 2's own 4,050.
    assert_equal [ Rational(-18, 100), Rational(-936, 100) ], forecast(frame("2026-03-01", "2026-05-29", earlier: [ first ]))
  end

  should "carry a unit the later step no longer holds as unplaced" do
    first = frame("2026-01-01", "2026-03-31")
    rows = TeamPlanning::RuleKinds::Attrition.forecast(frame("2026-04-01", "2026-06-29", earlier: [ first ], unit_ids: []))

    assert_equal [ nil, "platform" ], rows.map(&:unit_id).sort_by(&:to_s)
    assert_equal Rational(-81, 10), rows.find { it.unit_id.nil? }.cost.fetch("EUR"), "8,100 carried FTE-days × 0.001"
  end

  should "reach past its step only for a rate above 0, by the longest time to hire" do
    reach = ->(rates, days) { TeamPlanning::RuleKinds::Attrition.reach("attrition" => rates.map { { "yearly_rate" => it } }, "time_to_hire" => days.map { { "days" => it } }) }

    assert_nil reach.([ "0" ], [ "90" ])
    assert_equal 180, reach.([ "0", "0.1" ], [ "90", "180" ])
  end
end
