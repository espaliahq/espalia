# frozen_string_literal: true

require "test_helper"

class Views::Plans::BudgetTabTest < ActiveSupport::TestCase
  PLAN = "01a1da48-c64a-7529-af90-0f97e41cdd00"
  Q1 = "01a1da48-c64a-7529-af90-0f97e41cdd01"
  UNIT = "01a1da48-c64a-7529-af90-0f97e41cdd02"
  PLATFORM = "01a1da48-c64a-7529-af90-0f97e41cdd03"
  DOLLARS = "01a1da48-c64a-7529-af90-0f97e41cdd04"
  SEAT = "01a1da48-c64a-7529-af90-0f97e41cdd05"
  SHORT = "01a1da48-c64a-7529-af90-0f97e41cdd06"

  SCENARIOS = [
    { scenario_id: PLAN, parent_id: nil, relation: nil, name: "Pay review", starts_on: "2026-11-15", ends_on: nil },
    { scenario_id: Q1, parent_id: PLAN, relation: "then", name: "Q1 hires", starts_on: "2027-01-01", ends_on: "2027-03-31" }
  ].freeze

  def described(id, cost_centre:, currency: "EUR")
    { budget_line_id: id, amount: "146000", currency:, period: "year", head_count: "2", origin: "new", approved_on: nil,
      starts_on: "2027-01-01", ends_on: "2027-12-31", location: nil, cost_centre:, role: nil, level_name: nil, source: "espalia" }
  end

  def money(native, converted) = { native:, converted:, missing: [] }

  def line(id, remaining:, funded: { "EUR" => "9000" }, mismatched: [], over: nil)
    { budget_line_id: id, cost_centre: "Platform", currency: "EUR", approved: { amount: "36000", head_count: "2" },
      funded: { native: funded, positions: 1, fte: "0.5" }, remaining: { amount: remaining, head_count: "1.5" },
      mismatched_currencies: mismatched, over: over || { money: [], heads: false, mismatched_currencies: mismatched } }
  end

  OVER = { money: [ "EUR" ], heads: false, mismatched_currencies: [] }.freeze

  def budget(lines:, left_out: [], over: nil)
    { plan_id: PLAN, scenario_id: Q1, basis: "inclusive", period: { starts_on: "2027-01-01", ends_on: "2027-03-31" },
      pay_view: "band_midpoints", reference_currency: "EUR",
      total: { approved: { **money({ "EUR" => "72000" }, "72000"), head_count: "4" },
               funded: { **money({ "EUR" => "9000", "USD" => "5000" }, "13500"), positions: 2, fte: "1" },
               remaining: { **money({ "EUR" => "27000" }, "27000"), head_count: "3", left_out: { mismatched_currencies: left_out } },
               unfunded: { **money({}, "0"), positions: 0, fte: "0" }, over: },
      forecast: money({}, "0"), budget_lines: lines, cost_centres: [], units: [], unpriced: [] }
  end

  def funding(draws: { PLATFORM => [ SEAT ] }, unfunded: [])
    positions = [ SEAT, SHORT ].map do |id|
      { position_id: id, unit_id: UNIT, fte: "0.5", state: unfunded.include?(id) ? "unfunded" : "funded", reason: nil, reason_text: nil,
        draws: [], matching_ids: [] }
    end
    { plan_id: PLAN, scenario_id: Q1, positions:,
      budget_lines: draws.map { |id, ids| { budget_line_id: id, positions: ids.map { { position_id: it, share: "1", fte: "0.5", draw_reason: "open", starts_on: nil } } } } }
  end

  MAP = { units: [ { id: UNIT, name: "Payments" } ],
          positions: [ { position_id: SEAT, unit_id: UNIT, role_name: "Software Engineer", level_name: "Engineer II" },
                       { position_id: SHORT, unit_id: UNIT, role_name: "Software Engineer", level_name: "Engineer II" } ] }.freeze

  def render_tab(scenario_id: Q1, lines: [ described(PLATFORM, cost_centre: "Platform") ], scope: nil, money: true, **reads)
    controller = ApplicationController.new
    controller.request = ActionDispatch::TestRequest.create
    tab = Views::Plans::BudgetTab.new(plan: { plan_id: PLAN, name: "Pay review", scope: }, scenarios: SCENARIOS,
                                      lines: { plan_id: PLAN, scenario_id:, money:, budget_lines: lines, orphaned: [] }, **reads)
    Nokogiri::HTML5.fragment(controller.view_context.render(tab))
  end

  should "list Today's lines as approved and link every scenario's budget, with no funding figures" do
    html = render_tab(scenario_id: PLAN)

    assert_equal "Budget on Today", html.at_css("#budget-heading").text
    assert_equal [ "Q1 hires" ], html.css("[data-budget-today] a").map(&:text)
    assert_match "EUR 146,000 a year", html.at_css("[data-budget-line='#{PLATFORM}']").text
    assert_empty html.css("[data-budget-totals]")
  end

  should "say a scoped plan's totals cover only the lines its seats can draw on, on Today and in a scenario" do
    scoped = { whole_organisation: false, units: [ { unit_id: UNIT, name: "Payments" } ] }
    sentence = "Totals cover the budget lines this plan's seats can draw on."

    assert_equal sentence, render_tab(scenario_id: PLAN, scope: scoped).at_css("[data-budget-scope]").text
    assert_equal sentence, render_tab(scope: scoped, budget: budget(lines: [ line(PLATFORM, remaining: "27000") ]), funding:, map: MAP)
      .at_css("[data-budget-scope]").text
    assert_empty render_tab(scenario_id: PLAN, scope: { whole_organisation: true, units: [] }).css("[data-budget-scope]")
  end

  def without_money(read)
    hidden = ->(sum) { sum.merge(native: nil, converted: nil, missing: nil) }
    read.merge(money: false, forecast: hidden.(read[:forecast]),
               total: read[:total].to_h { |key, sum| [ key, sum.is_a?(Hash) ? hidden.(sum) : sum ] },
               budget_lines: read[:budget_lines].map do
                 it.merge(currency: nil, approved: it[:approved].merge(amount: nil), funded: it[:funded].merge(native: nil),
                          remaining: it[:remaining].merge(amount: nil), mismatched_currencies: [], over: it[:over].merge(money: nil))
               end)
  end

  # A budget amount is pay ([#367](https://github.com/espaliahq/espalia/issues/367)).
  should "show a member without the see-pay right head counts alone, never reading as a line with no amount" do
    hidden = { amount: nil, currency: nil, period: nil }
    lines = [ described(PLATFORM, cost_centre: "Platform").merge(hidden) ]
    html = render_tab(budget: without_money(budget(lines: [ line(PLATFORM, remaining: "27000", over: OVER) ])), funding:, map: MAP, lines:, money: false)
    today = render_tab(scenario_id: PLAN, lines:, money: false)

    assert_equal({ "approved" => "Head count 4", "funded" => "2 positions, 1 FTE", "remaining" => "Head count 3", "unfunded" => "0 positions, 0 FTE" },
                 html.css("[data-budget-total]").to_h { [ it["data-budget-total"], it.at_css("dd").text ] })
    assert_equal [ "Head count 2", "1 position, 0.5 FTE", "Head count 1.5" ], html.css("[data-budget-line='#{PLATFORM}'] dd").map(&:text).reject(&:empty?)
    assert_empty html.css("[data-budget-over]"), "over on money alone is no longer over"
    assert_not_includes html.at_css("[data-budget-line='#{PLATFORM}']").text, "Over", "nor is the line"
    [ html, today ].each do |page|
      assert_equal "Budget amounts show only to members who may see pay.", page.at_css("[data-budget-no-money]").text
      [ "EUR", "No amount", "a year", "base pay" ].each { assert_not_includes page.text, it }
    end
    assert_includes today.css("[data-budget-line='#{PLATFORM}'] p").map(&:text), "Head count 2"
    assert_nil render_tab(budget: budget(lines: [ line(PLATFORM, remaining: "27000") ]).merge(money: true), funding:, map: MAP).at_css("[data-budget-no-money]")
  end

  should "show a scenario's four numbers as the read gives them" do
    html = render_tab(budget: budget(lines: [ line(PLATFORM, remaining: "27000") ]), funding: funding, map: MAP)

    assert_equal %w[approved funded remaining unfunded], html.css("[data-budget-total]").map { it["data-budget-total"] }
    assert_match "EUR 13.5k", html.at_css("[data-budget-total='funded']").text
    assert_match "EUR 27k", html.at_css("[data-budget-line='#{PLATFORM}'] [data-budget-remaining]").text
  end

  should "flag a line drawn on in another currency, give it no remaining figure, and say the remaining total leaves it out" do
    html = render_tab(lines: [ described(PLATFORM, cost_centre: "Platform"), described(DOLLARS, cost_centre: "Platform") ],
                      budget: budget(lines: [ line(PLATFORM, remaining: "27000"),
                                              line(DOLLARS, remaining: nil, funded: { "USD" => "5000" }, mismatched: [ "USD" ]) ],
                                     left_out: [ DOLLARS ]),
                      funding: funding(draws: {}), map: MAP)
    dollars = html.at_css("[data-budget-line='#{DOLLARS}']")

    assert dollars.at_css("[data-budget-mismatch]")
    assert_match "Drawn on in USD", dollars.text
    assert_no_match(/EUR \d/, dollars.at_css("[data-budget-remaining]").text)
    assert_match "Not worked out", dollars.at_css("[data-budget-remaining]").text
    assert_equal "1", html.at_css("[data-budget-total='remaining'] [data-budget-left-out]")["data-budget-left-out"]
    assert_match "Leaves out 1 line drawn on in another currency", html.at_css("[data-budget-total='remaining']").text
    assert_nil html.at_css("[data-budget-line='#{PLATFORM}'] [data-budget-mismatch]")
  end

  should "fold a line's positions, open only when it is over or a position drawing on it is unfunded" do
    fine = render_tab(budget: budget(lines: [ line(PLATFORM, remaining: "27000") ]), funding: funding, map: MAP)
    over = render_tab(budget: budget(lines: [ line(PLATFORM, remaining: "-1000", over: OVER) ]), funding: funding, map: MAP)
    short = render_tab(budget: budget(lines: [ line(PLATFORM, remaining: "27000") ]),
                       funding: funding(draws: { PLATFORM => [ SEAT, SHORT ] }, unfunded: [ SHORT ]), map: MAP)

    assert_nil fine.at_css("[data-budget-draws]")["open"]
    assert_match "Software Engineer", fine.at_css("[data-budget-draw='#{SEAT}']").text
    assert_match "Payments", fine.at_css("[data-budget-draw='#{SEAT}']").text
    assert over.at_css("[data-budget-draws]")["open"]
    assert_match "Over", over.at_css("[data-budget-line='#{PLATFORM}']").text
    assert short.at_css("[data-budget-draws]")["open"]
    assert short.at_css("[data-budget-unfunded='#{SHORT}']")
  end

  should "mark over only what the read judges over, the remaining total included" do
    unjudged = render_tab(budget: budget(lines: [ line(PLATFORM, remaining: "-1000").merge(over: nil) ]), funding: funding, map: MAP)
    total = render_tab(budget: budget(lines: [ line(PLATFORM, remaining: "27000") ], over: { money: nil, heads: true, mismatched_currencies: [] }),
                       funding: funding, map: MAP)

    assert_no_match(/\bOver\b/, unjudged.at_css("[data-budget-line='#{PLATFORM}'] .flex").text)
    assert_nil unjudged.at_css("[data-budget-total='remaining'] [data-budget-over]")
    assert total.at_css("[data-budget-total='remaining'] [data-budget-over]")
    assert_no_match(/\bOver\b/, total.at_css("[data-budget-line='#{PLATFORM}'] .flex").text)
  end
end
