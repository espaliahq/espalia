# frozen_string_literal: true

require "test_helper"

class Views::Plans::CapacityFigureTest < ActiveSupport::TestCase
  PLAN = "01a1da48-c64a-7529-af90-0f97e41cda99"
  MODELS = { "units" => { symbol: "u", description: "Units on a curve" } }.freeze

  def marks
    payload = { plan_id: PLAN, scenario_id: PLAN, totals: {}, units: [], seats: [], unclassified: [], models: MODELS, names: {} }
    Views::Plans::CapacityMarks.new(scenario: payload, baseline: payload, names: {})
  end

  def figure(**place)
    place = { model: "units", capacity: "0", overridden: false, calculated: nil, overloaded: false, excess: "0", notes: [],
              working: [ { label: "Base for the level", amount: "1", op: "+", subject_id: nil } ], **place }
    Nokogiri::HTML5.fragment(Views::Plans::CapacityFigure.new(place:, marks:, label: "Ada").call).at_css("[data-capacity-figure]")
  end

  should "say a figure is overloaded, and by how much, in its working" do
    overloaded = figure(overloaded: true, excess: "0.35")

    assert_equal "Overloaded: managing others costs 0.4u more than this seat's base.",
                 overloaded.at_css("[data-capacity-overloaded]").text
    assert_nil figure.at_css("[data-capacity-overloaded]")
  end

  should "show the model's own overload and notes beside a planner's override" do
    model = { overloaded: true, excess: "0.35", notes: [ { note: "capped", text: "Capped at the level's ceiling" } ] }
    overridden = figure(overridden: true, capacity: "2", calculated: "1.2", calculated_diagnostics: model)

    assert_includes overridden.text, "The model gives 1.2u."
    assert_equal "Overloaded: managing others costs 0.4u more than this seat's base.", overridden.at_css("[data-capacity-overloaded]").text
    assert_includes overridden.text, "Capped at the level's ceiling"
  end

  should "badge an override even when the place it replaced counts nowhere" do
    unreadable = figure(capacity: nil, overridden: true, reason_text: "A planner overrode this figure")

    assert_includes unreadable.at_css("summary").text, "override"
    assert_not_includes figure.at_css("summary").text, "override"
  end
end
