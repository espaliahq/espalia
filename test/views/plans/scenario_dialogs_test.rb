# frozen_string_literal: true

require "test_helper"

class Views::Plans::ScenarioDialogsTest < ActiveSupport::TestCase
  PLAN = "01a1da48-c64a-7529-af90-0f97e41cda99"
  Q1 = "01a1da48-c64a-7529-af90-0f97e41cdaa0"
  Q2 = "01a1da48-c64a-7529-af90-0f97e41cdaa1"
  SLOW = "01a1da48-c64a-7529-af90-0f97e41cdaa2"
  AGREED = "01a1da48-c64a-7529-af90-0f97e41cdaa3"

  def scenario(id, parent_id, relation, name, ends_on: "2027-03-31") = { scenario_id: id, parent_id:, relation:, name:, starts_on: "2027-01-01", ends_on: }

  def render_dialogs(scenarios)
    controller = ApplicationController.new
    controller.request = ActionDispatch::TestRequest.create
    Nokogiri::HTML5.fragment(controller.view_context.render(Views::Plans::ScenarioDialogs.new(plan_id: PLAN, scenarios:)))
  end

  context ".default_parent" do
    should "start from today in a plan with no scenarios yet" do
      assert_equal PLAN, Views::Plans::ScenarioDialogs.default_parent(PLAN, [ scenario(PLAN, nil, nil, "Pay review") ])
    end

    should "follow the chain of scenarios after today to its end, past any alternatives" do
      scenarios = [ scenario(PLAN, nil, nil, "Pay review"), scenario(Q1, PLAN, "then", "Q1 hires"),
                    scenario(SLOW, Q1, "instead", "Slower hiring"), scenario(Q2, Q1, "then", "Q2 hires") ]

      assert_equal Q2, Views::Plans::ScenarioDialogs.default_parent(PLAN, scenarios)
    end

    should "pass up through the rest of a split step to the step after it" do
      scenarios = [ scenario(PLAN, nil, nil, "Pay review"), scenario(AGREED, PLAN, "then", "Agreed hires"),
                    scenario(Q1, AGREED, "on", "Q1 hires"), scenario(Q2, Q1, "then", "Q2 hires") ]

      assert_equal Q2, Views::Plans::ScenarioDialogs.default_parent(PLAN, scenarios)
      assert_equal Q2, Views::Plans::Timeline.first_leaf(scenarios, PLAN)
    end
  end

  should "list each scenario under the one it starts from, and mark those already followed, the agreed part of a split among them" do
    scenarios = [ scenario(PLAN, nil, nil, "Pay review"), scenario(AGREED, PLAN, "then", "Agreed hires"),
                  scenario(Q1, AGREED, "on", "Q1 hires"), scenario(SLOW, Q1, "instead", "Slower hiring") ]
    controller = ApplicationController.new
    controller.request = ActionDispatch::TestRequest.create
    html = Nokogiri::HTML5.fragment(controller.view_context.render(Views::Plans::ScenarioDialogs.new(plan_id: PLAN, scenarios:)))

    options = html.css("#fork-scenario-parent option").map { [ it.text, it["data-followed"] ] }
    assert_equal [ [ "Today", "true" ], [ "· Agreed hires", "true" ], [ "· · Q1 hires", "false" ], [ "· · · Slower hiring", "false" ] ],
                 options
  end

  should "mark each scenario whose period has no end, with the earliest start a step after it can take" do
    scenarios = [ scenario(PLAN, nil, nil, "Pay review", ends_on: nil), scenario(Q1, PLAN, "then", "Q1 hires", ends_on: nil),
                  scenario(SLOW, Q1, "instead", "Slower hiring", ends_on: nil) ]

    options = render_dialogs(scenarios).css("#fork-scenario-parent option").map { [ it.text, it["data-open"], it["data-earliest-start"] ] }
    assert_equal [ [ "Today", nil, nil ], [ "· Q1 hires", "true", "2027-01-02" ], [ "· · Slower hiring", "true", "2027-01-02" ] ], options
    assert_includes render_dialogs(scenarios).at_css("#fork-scenario-no-end-hint").text, "Cost and budget show a set number of months"
  end

  should "describe the end as a step's last day, true whether or not the step has a start of its own" do
    controller = ApplicationController.new
    controller.request = ActionDispatch::TestRequest.create
    html = Nokogiri::HTML5.fragment(controller.view_context.render(Views::Plans::ScenarioDialogs.new(plan_id: PLAN, scenarios: [ scenario(PLAN, nil, nil, "Pay review") ])))

    assert_equal "Its last day. A step after another starts the day after that one ends.", html.at_css("#fork-scenario-ends-on-hint").text
  end
end
