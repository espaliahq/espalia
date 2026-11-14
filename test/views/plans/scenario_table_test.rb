# frozen_string_literal: true

require "test_helper"

class Views::Plans::ScenarioTableTest < ActiveSupport::TestCase
  def periods(*scenarios)
    baseline = { scenario_id: "plan", parent_id: nil, relation: nil, name: "Pay review", starts_on: "2026-11-14", ends_on: nil }
    html = render_view(Views::Plans::ScenarioTable.new(scenarios: [ baseline, *scenarios ]))
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
      assert_equal "From 1 Apr 2027", periods(step("2027-04-01", nil)).last
    end
  end
end
