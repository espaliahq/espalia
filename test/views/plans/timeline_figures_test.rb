# frozen_string_literal: true

require "test_helper"

class Views::Plans::TimelineFiguresTest < ActiveSupport::TestCase
  PLAN = "01a1da48-c64a-7529-af90-0f97e41cda99"
  STEP = "01a1da48-c64a-7529-af90-0f97e41cda9a"
  NONE = { native: {}, converted: nil, missing: [] }.freeze

  def eur(amount) = { native: { "EUR" => amount }, converted: amount, missing: [] }

  def step(**over)
    { scenario_id: STEP, basis: "period", period: { open_ended: false, horizon_months: nil }, cost: eur("100000"), unpriced: 0,
      budget: nil, capacity: {}, **over }
  end

  def budget(approved: eur("150000"), unfunded: NONE, positions: 0, over: nil)
    { approved:, unfunded: { **unfunded, positions:, fte: positions.to_s }, over: }
  end

  def lines(step, money: true)
    figures = { plan_id: PLAN, money:, reference_currency: "EUR", steps: [ step ] }
    controller = ApplicationController.new
    controller.request = ActionDispatch::TestRequest.create
    html = controller.view_context.render(Views::Plans::TimelineFigures.new(figures:, scenarios: [ { scenario_id: STEP, name: "Q1 hires" } ]))
    Nokogiri::HTML5.fragment(html).css("[data-timeline-figure]").to_h { [ it["data-timeline-figure"], it.text ] }
  end

  should "say over what a step's cost runs: a year for Today, the step, or the months an open step shows" do
    assert_equal "EUR 100k a year", lines(step(scenario_id: PLAN, basis: "run_rate"))["cost"]
    assert_equal "EUR 100k over the step", lines(step)["cost"]
    assert_equal "EUR 100k over the 12 months shown", lines(step(period: { open_ended: true, horizon_months: 12 }))["cost"]
  end

  should "count unpriced seats beside the cost, and say No cost when there is none" do
    assert_equal "EUR 100k over the step · 1 seat unpriced", lines(step(unpriced: 1))["cost"]
    assert_equal "2 seats unpriced", lines(step(cost: NONE, unpriced: 2))["cost"]
    assert_equal "No cost", lines(step(cost: NONE))["cost"]
  end

  should "read a budget in money with the see-pay right, and in positions without it" do
    assert_equal "Budget EUR 150k · all funded", lines(step(budget: budget))["budget"]
    assert_equal "Budget EUR 150k · EUR 50k unfunded", lines(step(budget: budget(unfunded: eur("50000"), positions: 1)))["budget"]
    assert_equal "No budget · EUR 50k unfunded", lines(step(budget: budget(approved: NONE, unfunded: eur("50000"))))["budget"]
    assert_equal "Budget EUR 150k · 1 position unfunded", lines(step(budget: budget(positions: 1)))["budget"]
    assert_equal "All positions funded", lines(step(budget: budget), money: false)["budget"]
    assert_equal "1 position unfunded", lines(step(budget: budget(positions: 1)), money: false)["budget"]
  end

  should "flag a step over its budget, and leave Today with no budget line" do
    assert_equal "Budget EUR 150k · all funded · over", lines(step(budget: budget(over: { money: [ "EUR" ], heads: false })))["budget"]
    assert_equal "All positions funded · over", lines(step(budget: budget(over: { money: [], heads: true })), money: false)["budget"]
    assert_nil lines(step(scenario_id: PLAN, basis: "run_rate"))["budget"]
  end

  should "show each capacity model's figure with its symbol" do
    assert_equal "2.5u · 3.0 FTE", lines(step(capacity: { "units" => "2.5", "per_fte" => "3" }))["capacity"]
  end
end
