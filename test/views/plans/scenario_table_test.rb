# frozen_string_literal: true

require "test_helper"

class Views::Plans::ScenarioTableTest < ActiveSupport::TestCase
  def periods(*scenarios)
    baseline = { scenario_id: "plan", parent_id: nil, relation: nil, name: "Pay review", starts_on: "2026-11-14", ends_on: nil }
    html = render_view(Views::Plans::ScenarioTable.new(plan_id: "plan", scenarios: [ baseline, *scenarios ]))
    Nokogiri::HTML5.fragment(html).css("tbody tr").map { it.css("td")[1].text.strip }
  end

  def render_view(view)
    controller = ApplicationController.new
    controller.request = ActionDispatch::TestRequest.create
    controller.view_context.render(view)
  end

  def step(starts_on, ends_on) = { scenario_id: SecureRandom.uuid, parent_id: "plan", relation: "then", name: "Step", starts_on:, ends_on: }

  context "a scenario's period" do
    should "name the baseline's date" do
      assert_equal [ "As of 14 Nov 2026" ], periods
    end

    should "name whole months, and one month once" do
      assert_equal "Apr to Jun 2027", periods(step("2027-04-01", "2027-06-30")).last
      assert_equal "Apr 2027", periods(step("2027-04-01", "2027-04-30")).last
      assert_equal "Dec 2026 to Feb 2027", periods(step("2026-12-01", "2027-02-28")).last
    end

    should "name the days when a period doesn't start and end on a month's edges" do
      assert_equal "16 Mar to 30 Apr 2027", periods(step("2027-03-16", "2027-04-30")).last
      assert_equal "14 Nov 2026 to 31 Mar 2027", periods(step("2026-11-14", "2027-03-31")).last
    end

    should "say when an open-ended scenario starts" do
      assert_equal "From 1 Apr 2027 · no end date", periods(step("2027-04-01", nil)).last
    end

    should "name the months a step with no end date is figured over" do
      assert_equal "1 Apr 2027 to 31 Mar 2028, the first 12 months of a step with no end date",
                   Views::Plans::ScenarioTable.figured({ starts_on: "2027-04-01", ends_on: "2028-03-31", open_ended: true, horizon_months: 12 })
      assert_equal "1 Apr 2027 to 30 Jun 2027",
                   Views::Plans::ScenarioTable.figured({ starts_on: "2027-04-01", ends_on: "2027-06-30", open_ended: false, horizon_months: nil })
    end
  end

  should "show a scenario's description under its name, as prose" do
    baseline = { scenario_id: "plan", parent_id: nil, relation: nil, name: "Pay review", starts_on: "2026-11-14", ends_on: nil }
    q1 = step("2027-01-01", "2027-03-31").merge(name: "Q1 hires", description: "Hire **two** seniors")
    html = Nokogiri::HTML5.fragment(render_view(Views::Plans::ScenarioTable.new(plan_id: "plan", scenarios: [ baseline, q1 ])))

    prose = html.css("tbody tr")[1].at_css("td .md-prose")
    assert_equal "Hire two seniors", prose.text.strip
    assert prose.at_css("strong")
    assert_nil html.css("tbody tr")[0].at_css(".md-prose")
  end

  should "offer the rest of a split the Dates… of its agreed step, and an alternative none" do
    baseline = { scenario_id: "plan", parent_id: nil, relation: nil, name: "Pay review", starts_on: "2026-11-14", ends_on: nil }
    agreed = step("2026-11-14", "2027-03-31").merge(name: "Agreed Q1")
    rest = agreed.merge(scenario_id: SecureRandom.uuid, parent_id: agreed[:scenario_id], relation: "on", name: "Q1 hires")
    other = agreed.merge(scenario_id: SecureRandom.uuid, parent_id: agreed[:scenario_id], relation: "instead", name: "Q1 freeze")
    html = Nokogiri::HTML5.fragment(render_view(Views::Plans::ScenarioTable.new(plan_id: "plan", scenarios: [ baseline, agreed, rest, other ],
                                                                                can_edit: true)))
    dates = ->(scenario) { html.at_css("tr[data-scenario-id='#{scenario[:scenario_id]}']").css("a").find { it.text == "Dates…" }&.[]("href") }

    assert_equal "/planning/plan/scenarios/#{agreed[:scenario_id]}/dates", dates.(rest)
    assert_nil dates.(other)
  end

  should "find the step a scenario takes its dates from, through splits and alternatives" do
    agreed = step("2026-11-14", "2027-03-31")
    rest = agreed.merge(scenario_id: SecureRandom.uuid, parent_id: agreed[:scenario_id], relation: "on")
    other = agreed.merge(scenario_id: SecureRandom.uuid, parent_id: rest[:scenario_id], relation: "instead")
    scenarios = [ agreed, rest, other ]

    assert_equal agreed, Views::Plans::ScenarioTable.period_owner(other, scenarios)
    assert_equal agreed, Views::Plans::ScenarioTable.dated_step(rest, scenarios)
    assert_nil Views::Plans::ScenarioTable.dated_step(other, scenarios)
    assert_nil Views::Plans::ScenarioTable.period_owner({ scenario_id: "plan", parent_id: nil, relation: nil }, scenarios)
  end

  should "draw a visible kebab on each row's menu, sized to stay inside the table" do
    baseline = { scenario_id: "plan", parent_id: nil, relation: nil, name: "Pay review", starts_on: "2026-11-14", ends_on: nil }
    html = Nokogiri::HTML5.fragment(render_view(Views::Plans::ScenarioTable.new(plan_id: "plan", scenarios: [ baseline ], can_edit: true)))
    trigger = html.at_css("[aria-label='Actions for Today']")

    assert trigger.at_css("svg use"), "the trigger has no glyph"
    assert_not_includes trigger["class"], Components::Kit::Button::HIT_AREA, "the 44px tap box spills out of the scrolling table"
  end
end
