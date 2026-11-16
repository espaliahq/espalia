# frozen_string_literal: true

require "test_helper"

class Views::Plans::TimelineTest < ActiveSupport::TestCase
  PLAN = "01a1da48-c64a-7529-af90-0f97e41cdb00"
  Q1 = "01a1da48-c64a-7529-af90-0f97e41cdb01"
  PAYMENTS = "01a1da48-c64a-7529-af90-0f97e41cdb02"
  ADA = "01a1da48-c64a-7529-af90-0f97e41cdb03"

  SCENARIOS = [
    { scenario_id: PLAN, parent_id: nil, relation: nil, name: "Pay review", starts_on: "2026-11-15", ends_on: nil },
    { scenario_id: Q1, parent_id: PLAN, relation: "then", name: "Q1 hires", starts_on: "2027-01-01", ends_on: "2027-03-31" }
  ].freeze

  Q2 = "01a1da48-c64a-7529-af90-0f97e41cdb04"
  Q3 = "01a1da48-c64a-7529-af90-0f97e41cdb05"
  FOUR_STEPS = [
    *SCENARIOS,
    { scenario_id: Q2, parent_id: Q1, relation: "then", name: "Q2 settle", starts_on: "2027-04-01", ends_on: "2027-06-30" },
    { scenario_id: Q3, parent_id: Q2, relation: "then", name: "Q3 grow", starts_on: "2027-07-01", ends_on: nil }
  ].freeze

  # `movable` lists, per column, the changes that column's step makes itself.
  def render_timeline(bars:, moves: [], departures: [], unassigned: false, step: 0, scenarios: SCENARIOS, movable: {}, can_edit: false,
                      walk: steady_walk(scenarios.size), unit_walk: walk, units: nil)
    timeline = {
      walk:, unassigned_walk: steady_walk(scenarios.size, heads: 0),
      plan_id: PLAN, scenario_id: scenarios.last[:scenario_id], next_ids: [],
      columns: scenarios.each_with_index.map do |scenario, index|
        { scenario_id: scenario[:scenario_id], name: scenario[:name], alternative_ids: [], movable: movable.fetch(index, []) }
      end,
      blocks: [ { block_id: PAYMENTS, units: units || ([ { unit_id: PAYMENTS, name: "Payments" } ] * scenarios.size), continues_from_ids: [], lane_ids: [ ADA ], walk: unit_walk } ],
      unassigned_lane_ids: unassigned ? [ ADA ] : [],
      lanes: [ { lane_id: ADA, bars:, moves:, departures: } ],
      positions: {}, names: { ADA => "Ada Quill" }
    }
    controller = ApplicationController.new
    controller.request = ActionDispatch::TestRequest.create
    Nokogiri::HTML5.fragment(controller.view_context.render(Views::Plans::Timeline.new(timeline:, scenarios:, step:, can_edit:)))
  end

  def steady_walk(size, heads: 1)
    [ counts(nil, closing: heads), *Array.new(size - 1) { counts(heads, closing: heads) } ]
  end

  def counts(opening, closing:, hires: 0, transfers_in: 0, departures: 0, transfers_out: 0)
    { opening:, hires: opening && hires, transfers_in: opening && transfers_in, departures: opening && departures,
      transfers_out: opening && transfers_out, closing: }
  end

  def grip_targets(html, edge)
    grips = html.css("[data-timeline-shift-edge='#{edge}']")
    grips.map { JSON.parse(it["data-timeline-shift-targets"]) }
  end

  def bar(from, to, unit_id: PAYMENTS, role: "ENG")
    { kind: "person", subject_id: ADA, from:, to:, unit_id:, position_id: nil, allocation: 1.0, role:, replaces_id: nil }
  end

  def wide_labels(html) = html.css("[data-timeline-grid] div.uppercase").map(&:text) - [ "Step" ]

  context "a person whose role changes in one unit" do
    should "label each role on a row of its own" do
      html = render_timeline(bars: [ bar(0, 0, role: "ENG"), bar(1, 1, role: "PM") ])

      assert_equal %w[ENG PM], wide_labels(html)
    end
  end

  context "a person who moves to Unassigned" do
    setup do
      @html = render_timeline(bars: [ bar(0, 0), bar(1, 1, unit_id: nil) ], unassigned: true,
                              moves: [ { person_id: ADA, after: 0, left_unit_ids: [ PAYMENTS ], joined_unit_ids: [ nil ] } ])
    end

    should "say where they go and where they came from" do
      lanes = @html.css("[data-timeline-grid] [data-timeline-lane]").map(&:text)

      assert lanes.any? { it.include?("Ada Quillto Unassigned") }, lanes.inspect
      assert lanes.any? { it.include?("from PaymentsAda Quill") }, lanes.inspect
    end
  end

  context "a person who crosses the edge of a scoped plan" do
    should "say they move out of it, and that they join it" do
      out = render_timeline(bars: [ bar(0, 0) ], moves: [ { person_id: ADA, after: 0, left_unit_ids: [ PAYMENTS ], joined_unit_ids: [], crossing: "out" } ])
      joins = render_timeline(bars: [ bar(1, 1) ], moves: [ { person_id: ADA, after: 0, left_unit_ids: [], joined_unit_ids: [ PAYMENTS ], crossing: "in" } ])

      assert_includes out.css("[data-timeline-grid] [data-timeline-lane]").map(&:text).join, "Ada Quillmoves out of this plan"
      assert_includes joins.css("[data-timeline-grid] [data-timeline-lane]").map(&:text).join, "joins this planAda Quill"
    end
  end

  context "dragging a bar's edge" do
    setup do
      @place = { 2 => [ { subject_id: ADA, facet: "assignment" } ] }
      @leaves = { 2 => [ { subject_id: ADA, facet: "departure" } ] }
      @leaving = [ { person_id: ADA, column: 2, position_id: nil } ]
    end

    should "give a bar that starts with a change of place a start grip to the steps either side" do
      html = render_timeline(bars: [ bar(2, 3) ], scenarios: FOUR_STEPS, movable: @place, can_edit: true)

      assert_equal [ [ 1, 3 ] ], grip_targets(html, "start")
      assert_empty grip_targets(html, "end")
      later = html.at_css("a[data-turbo-method='post'][data-timeline-shift='start:3']")
      assert_includes later["href"], "direction%5D=later", "the drop clicks the When… item that moves it later"
      assert html.at_css("a[data-timeline-shift='start:1']"), "and the one that moves it earlier"
    end

    should "give a bar whose last step is a departure an end grip" do
      html = render_timeline(bars: [ bar(0, 2) ], departures: @leaving, scenarios: FOUR_STEPS, movable: @leaves, can_edit: true)

      assert_equal [ [ 1, 3 ] ], grip_targets(html, "end")
      assert_empty grip_targets(html, "start")
      assert_equal %w[end:1 end:3], html.css("a[data-timeline-shift]").map { it["data-timeline-shift"] }
    end

    should "never offer Today, and offer only later from the first step after it" do
      html = render_timeline(bars: [ bar(1, 3) ], scenarios: FOUR_STEPS, movable: { 1 => [ { subject_id: ADA, facet: "assignment" } ] }, can_edit: true)

      assert_equal [ [ 2 ] ], grip_targets(html, "start")
    end

    should "offer only earlier from the open-ended last step" do
      html = render_timeline(bars: [ bar(3, 3) ], scenarios: FOUR_STEPS, movable: { 3 => [ { subject_id: ADA, facet: "assignment" } ] }, can_edit: true)

      assert_equal [ [ 2 ] ], grip_targets(html, "start")
    end

    should "keep a level change in the middle of a position's bar on the menu only" do
      position = { kind: "position", subject_id: ADA, from: 1, to: 3, unit_id: PAYMENTS, position_id: ADA, role: "ENG", level: "L3" }
      html = render_timeline(bars: [ position ], scenarios: FOUR_STEPS, movable: { 2 => [ { subject_id: ADA, facet: "position" } ] }, can_edit: true)

      assert_empty html.css("[data-timeline-shift-edge], a[data-timeline-shift]")
      assert html.css("button").any? { it.text.include?("When…") }
    end

    should "keep the grip out of the tab order and from screen readers" do
      grip = render_timeline(bars: [ bar(2, 3) ], scenarios: FOUR_STEPS, movable: @place, can_edit: true).at_css("[data-timeline-shift-edge]")

      assert_equal "true", grip["aria-hidden"]
      assert_nil grip["tabindex"]
      assert_equal "span", grip.name
    end

    should "draw no grips for someone who can't edit, as on an archived or frozen plan" do
      html = render_timeline(bars: [ bar(2, 3) ], scenarios: FOUR_STEPS, movable: @place, can_edit: false)

      assert_empty html.css("[data-timeline-shift-edge], [data-timeline-shift-column], [data-timeline-shift-hint]")
    end

    should "draw no grips on a phone" do
      html = render_timeline(bars: [ bar(2, 3) ], scenarios: FOUR_STEPS, movable: @place, can_edit: true, step: 2)

      assert_empty html.css("[data-timeline-phone] [data-timeline-shift-edge]")
      assert_equal 1, html.css("[data-timeline-grid] [data-timeline-shift-edge]").size
    end
  end

  context "the headcount walk" do
    should "put the plan's walk under each step and each unit's in its heading row, naming only what changed" do
      walk = [ counts(nil, closing: 3), counts(3, closing: 4, hires: 2, departures: 1) ]
      unit_walk = [ counts(nil, closing: 2), counts(2, closing: 2, transfers_in: 1, transfers_out: 1) ]
      html = render_timeline(bars: [ bar(0, 1) ], walk:, unit_walk:)
      header = html.css("[data-timeline-step] [data-walk]").map { it.text.squish }
      unit = html.css("[data-timeline-walk] [data-walk]").map { it.text.squish }

      assert_equal [ "3 heads", "3 → to 4 heads · 2 hired, 1 left" ], header
      assert_equal [ "Today: 2 heads", "Q1 hires: 2 → to 2 heads · 1 moved in, 1 moved out" ], unit
      assert_equal "true", html.at_css("[data-timeline-step='1'] [data-walk] span[aria-hidden]")["aria-hidden"]
    end

    should "leave Unassigned's heading out until someone is in it, and show a phone the step's walk and each unit's" do
      html = render_timeline(bars: [ bar(0, 1) ], step: 1, walk: [ counts(nil, closing: 1), counts(1, closing: 2, hires: 1) ], unit_walk: steady_walk(2))
      phone = html.at_css("[data-timeline-phone]")

      assert_equal [ "1 → to 2 heads · 1 hired", "1 head" ], phone.css("[data-walk]").map { it.text.squish }
      assert_not html.text.include?(Views::Plans::Timeline::UNASSIGNED)
    end

    should "show the walk out of a unit in the step it retires in, and of a unit a step empties, on a phone too" do
      emptied = [ counts(nil, closing: 2), counts(2, closing: 0, transfers_out: 2) ]
      retired = render_timeline(bars: [ bar(0, 0) ], unit_walk: emptied, units: [ { unit_id: PAYMENTS, name: "Payments" }, nil ])
      phone = render_timeline(bars: [ bar(0, 0) ], unit_walk: emptied, step: 1).at_css("[data-timeline-phone]")

      assert_equal "Q1 hires: 2 → to 0 heads · 2 moved out", retired.at_css("[data-timeline-walk='1']").text.squish
      assert_equal [ "1 head", "2 → to 0 heads · 2 moved out" ], phone.css("[data-walk]").map { it.text.squish }
      assert_includes phone.text, "Payments"
    end
  end
end
