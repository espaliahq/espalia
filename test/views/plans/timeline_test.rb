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

  def render_timeline(bars:, moves: [], unassigned: false, step: 0)
    timeline = {
      plan_id: PLAN, scenario_id: Q1, next_ids: [],
      columns: SCENARIOS.map { { scenario_id: it[:scenario_id], name: it[:name], alternative_ids: [] } },
      blocks: [ { block_id: PAYMENTS, units: [ { unit_id: PAYMENTS, name: "Payments" } ] * 2, continues_from_ids: [], lane_ids: [ ADA ] } ],
      unassigned_lane_ids: unassigned ? [ ADA ] : [],
      lanes: [ { lane_id: ADA, bars:, moves:, departures: [] } ],
      positions: {}, names: { ADA => "Ada Quill" }
    }
    controller = ApplicationController.new
    controller.request = ActionDispatch::TestRequest.create
    Nokogiri::HTML5.fragment(controller.view_context.render(Views::Plans::Timeline.new(timeline:, scenarios: SCENARIOS, step:)))
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
end
