# frozen_string_literal: true

require "test_helper"

class Views::Plans::SplitScenarioTest < ActiveSupport::TestCase
  PLAN = "01a1da48-c64a-7529-af90-0f97e41cdc00"
  Q1 = "01a1da48-c64a-7529-af90-0f97e41cdc01"
  ADA = "01a1da48-c64a-7529-af90-0f97e41cdc02"
  CORE = "01a1da48-c64a-7529-af90-0f97e41cdc03"
  EDGE = "01a1da48-c64a-7529-af90-0f97e41cdc04"
  PLATFORM = "01a1da48-c64a-7529-af90-0f97e41cdc05"
  BO = "01a1da48-c64a-7529-af90-0f97e41cdc06"

  def render_page(needs)
    plan = { plan_id: PLAN, name: "Next year", base_on: "2026-03-02" }
    controller = ApplicationController.new
    controller.request = ActionDispatch::TestRequest.create
    Nokogiri::HTML5.fragment(controller.view_context.render(Views::Plans::SplitScenario.new(plan:, scenario: { scenario_id: Q1, name: "Q1" }, needs:)))
  end

  should "name a need that can't go across once, however many changes lead to it" do
    platform = { event_id: nil, subject_id: PLATFORM, facet: "unit" }
    needs = {
      changes: [
        { event_id: "a", subject_id: ADA, facet: "placement", needs: [ { event_id: "core", subject_id: CORE, facet: "unit" },
                                                                         { event_id: "edge", subject_id: EDGE, facet: "unit" } ] },
        { event_id: "core", subject_id: CORE, facet: "unit", needs: [ platform ] },
        { event_id: "edge", subject_id: EDGE, facet: "unit", needs: [ platform ] },
        { event_id: "bo", subject_id: BO, facet: "level", needs: [] }
      ],
      names: { ADA => "Ada Quill", CORE => "Core", EDGE => "Edge", PLATFORM => "Platform", BO => "Bo Reyes" }
    }

    text = render_page(needs).at_css("[data-split-change='a'] [data-split-needs]").text

    assert_equal "Can't go across. It needs Core: Unit, Platform: Unit, and Edge: Unit, and no change in this scenario makes that any more.", text
  end
end
