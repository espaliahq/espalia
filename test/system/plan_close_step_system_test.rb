# frozen_string_literal: true

require "application_system_test_case"

# Closing a step once its period has ended, and reopening it, from the plan
# page and the timeline ([#466](https://github.com/espaliahq/espalia/issues/466)).
class PlanCloseStepSystemTest < ApplicationSystemTestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @editor = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant, name: "Erin Editor"))
      @viewer = create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant))
      @plan_id = call(Operations::TeamPlanning::CreatePlan, name: "Next year", base_on: (Date.current - 90).iso8601)[:plan_id]
      call(Operations::TeamPlanning::AddPlanMember, plan_id: @plan_id, person_id: @viewer.person_id, role: "viewer")
      @q1 = call(Operations::TeamPlanning::ForkScenario, plan_id: @plan_id, relation: "then", name: "Q1",
                                                         ends_on: (Date.current - 1).iso8601)[:scenario_id]
      @lean = call(Operations::TeamPlanning::ForkScenario, plan_id: @plan_id, parent_id: @q1, relation: "instead", name: "Lean Q1")[:scenario_id]
      @q2 = call(Operations::TeamPlanning::ForkScenario, plan_id: @plan_id, parent_id: @q1, relation: "then", name: "Q2",
                                                         ends_on: (Date.current + 90).iso8601)[:scenario_id]
    end
  end

  [ [ "desktop", DESKTOP_SIZE ], [ "phone", MOBILE_SIZE ] ].each do |label, size|
    context "on a #{label}" do
      setup { page.driver.browser.manage.window.resize_to(*size) }

      should "close a step from its row, saying what that does, and reopen it" do
        sign_in_as(@editor.user)
        visit plan_path(@plan_id)
        assert_selector "h1", text: "Next year"
        row = "tr[data-scenario-id='#{@q1}']"
        assert_selector "#{row} [data-step-state=ready_to_close]", text: "Ready to close"
        scroll_to(find(row), align: :center)
        open_dropdown(scope: row)
        click_button_with_js_fallback("Close step…", expect_text: "Close Q1?")

        within("#step-closure-#{@q1}") do
          assert_text "The steps after it will start from the organisation as the Org Graph holds it on #{Date.current.strftime('%-d %b %Y')}."
          assert_text "Lean Q1 will read Not taken."
        end
        assert_no_sideways_overflow
        click_button_with_js_fallback("Close step", expect_text: "Closed Q1.")

        assert_selector "#{row} [data-step-state=closed]", text: "on #{Date.current.strftime('%-d %b')} by Erin Editor"
        assert_selector "tr[data-scenario-id='#{@lean}'] [data-step-state=not_taken]", text: "Not taken"
        assert_no_sideways_overflow
        scroll_to(find(row), align: :center)
        open_dropdown(scope: row)
        click_button_with_js_fallback("Reopen step…", expect_text: "Reopen Q1?")
        within("#step-closure-#{@q1}") do
          assert_text "The steps after it will stand where they stood before it closed: on the step closed before it, " \
                      "or on the plan's own base if no step closed before it."
        end
        click_button_with_js_fallback("Reopen step", expect_text: "Reopened Q1.")

        assert_selector "#{row} [data-step-state=ready_to_close]"
      end

      should "close a step from the timeline and land back on it" do
        sign_in_as(@editor.user)
        visit timeline_plan_path(@plan_id, scenario: @q2, step: 1)
        assert_selector "h1", text: "Next year"
        click_button_with_js_fallback("Close step…", expect_text: "Close Q1?")
        click_button_with_js_fallback("Close step", expect_text: "Closed Q1.")

        assert_current_path timeline_plan_path(@plan_id, scenario: @q2, step: 1)
        assert_selector "[data-step-state=closed]", text: "Closed"
        assert_button "Reopen step…"
        assert_no_sideways_overflow
      end
    end
  end

  should "show a viewer each step's state but no Close" do
    sign_in_as(@viewer.user)
    visit plan_path(@plan_id)
    assert_selector "h1", text: "Next year"
    assert_selector "[data-step-state=ready_to_close]", text: "Ready to close"
    assert_no_selector "[data-modal-target-id^='step-closure-']", visible: :all
  end

  private

  def call(operation, **params)
    operation.call(context: AuthorizationContext.new(user: @editor.user, tenant_user: @editor, person: @editor.person), params:)
  end
end
