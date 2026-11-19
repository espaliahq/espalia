# frozen_string_literal: true

require "test_helper"

class Views::Plans::ChecksTabTest < ActiveSupport::TestCase
  PLAN = "01a1da48-c64a-7529-af90-0f97e41cdd00"
  Q1 = "01a1da48-c64a-7529-af90-0f97e41cdd01"
  ADA = "01a1da48-c64a-7529-af90-0f97e41cdd04"
  RISK = "01a1da48-c64a-7529-af90-0f97e41cdd05"

  SCENARIOS = [
    { scenario_id: PLAN, parent_id: nil, relation: nil, name: "Pay review", starts_on: "2026-11-15", ends_on: nil },
    { scenario_id: Q1, parent_id: PLAN, relation: "then", name: "Q1 hires", starts_on: "2027-01-01", ends_on: "2027-03-31" }
  ].freeze

  def item(check, subject_id: ADA, facet: "assignment", reason: "Placed in a retired unit", change: nil, sources: %w[espalia])
    { check: check.to_s, subject_id:, facet:, reason:, change:, sources: }
  end

  def change(event_id, scenario_id: PLAN) = { kind: "UnitRetired", scenario_id:, event_id: }

  def render_tab(items: [], scenario_id: Q1, linked_ids: Set.new, unchecked: [])
    attention = { plan_id: PLAN, scenario_id:, items:, names: { ADA => "Ada Quill", RISK => "Risk" }, unchecked: }
    controller = ApplicationController.new
    controller.request = ActionDispatch::TestRequest.create
    Nokogiri::HTML5.fragment(controller.view_context.render(
      Views::Plans::ChecksTab.new(plan: { plan_id: PLAN, name: "Pay review" }, scenarios: SCENARIOS, attention:, linked_ids:)
    ))
  end

  should "give every check Attention runs a heading of its own" do
    assert_empty TeamPlanning::Attention::CHECKS - Views::Plans::ChecksTab::HEADINGS.keys,
                 "Add a heading and sentence to Views::Plans::ChecksTab::HEADINGS"
  end

  should "group items by check in the order they come, with a count for each that links to its group" do
    html = render_tab(items: [ item(:placements), item(:units, subject_id: RISK, facet: "unit", reason: "Its parent is a retired unit"),
                               item(:leavers, reason: "Placed, but has since left") ])

    assert_equal TeamPlanning::Attention::CHECKS.map(&:to_s), html.css("[data-check]").map { it["data-check"] }
    assert_equal [ "Placements 1", "Units 1", "Leavers 1" ], html.css("nav[aria-label='Checks'] a").map { it.text.squish }
    assert_equal "#checks-units", html.css("nav[aria-label='Checks'] a")[1]["href"]
    assert_equal "Risk · Unit", html.at_css("#checks-units [data-check-item] strong").parent.text.squish
  end

  should "give a check that found nothing an empty state of its own, and leave it out of the counts" do
    html = render_tab(items: [ item(:placements) ])

    assert_includes html.at_css("#checks-managers").text, "Nothing to fix here."
    assert_nil html.at_css("#checks-managers [data-check-item]")
    assert_not_includes html.at_css("#checks-placements").text, "Nothing to fix here."
    assert_equal [ "Placements 1" ], html.css("nav[aria-label='Checks'] a").map { it.text.squish }
  end

  should "say a check did not run, rather than that everything fits" do
    html = render_tab(unchecked: %w[misfits])

    assert_not_includes html.text, "Everything in this scenario still fits."
    assert_equal "Unit types not checked: the Org Graph is being rebuilt. Try again in a minute.",
                 html.at_css("[data-checks-not-run='misfits'][role='status']").text.squish
    assert_equal Views::Plans::ChecksTab::UNCHECKED_LINE, html.at_css("#checks-misfits [data-check-unchecked='misfits']").text
    assert_not_includes html.at_css("#checks-misfits").text, "Nothing to fix here."
    assert_includes html.at_css("#checks-units").text, "Nothing to fix here."
  end

  should "show a check with no heading under its key, with its items" do
    html = render_tab(items: [ item(:overloaded_managers, reason: "Manages 14 people") ])

    assert_equal "overloaded_managers", html.at_css("#checks-overloaded-managers h4").text
    assert_includes html.at_css("#checks-overloaded-managers").text, "Manages 14 people"
  end

  should "link a change to its row in the Changes tab, and name one the tab doesn't list without a link" do
    html = render_tab(items: [ item(:placements, change: change("e1")), item(:units, subject_id: RISK, facet: "unit", change: change("e2", scenario_id: Q1)),
                               item(:allocations, reason: "Placed nowhere") ], linked_ids: Set["e1"])

    rows = html.css("[data-check-item]")
    link = rows[0].at_css("a")
    assert_equal "a change in Today", link.text
    assert_equal "/planning/#{PLAN}/changes?scenario=#{Q1}#change-e1", link["href"]
    assert_nil rows[1].at_css("a")
    assert_includes rows[1].text, "From a change in Q1 hires"
    assert_includes rows[2].text, "Nothing in the plan explains it."
  end

  should "name where to fix each item" do
    html = render_tab(items: [ item(:placements, sources: %w[espalia hibob]) ])

    row = html.at_css("[data-check-item]").text
    assert_includes row, "Source: Espalia"
    assert_includes row, "Source: HiBob"
  end

  should "say everything fits when no check finds anything, on Today as on a scenario" do
    [ PLAN, Q1 ].each do |scenario_id|
      html = render_tab(scenario_id:)
      assert_includes html.text, "Everything in this scenario still fits."
      assert_nil html.at_css("nav[aria-label='Checks']")
    end
    assert_equal "Checks on Today", render_tab(scenario_id: PLAN).at_css("#checks-heading").text
  end

  should "pick a scenario by pill on a wide screen and by list on a phone, Today as the bare URL" do
    html = render_tab

    assert_equal "Q1 hires", html.at_css("nav[aria-label='Scenario'] a[aria-current='page']").text
    assert_equal "/planning/#{PLAN}/checks", html.css("nav[aria-label='Scenario'] a").first["href"]
    assert_equal Q1, html.at_css("#checks-scenario option[selected]")["value"]
  end

  should "name each facet as the Changes tab does, a plan value included" do
    html = render_tab(items: [ item(:allocations, facet: "data:fte"), item(:capacity_overrides, facet: "capacity:#{RISK}") ])

    assert_equal [ "Ada Quill · Capacity", "Ada Quill · FTE (plan value)" ], html.css("[data-check-item] p:first-child").map { it.text.squish }
  end
end
