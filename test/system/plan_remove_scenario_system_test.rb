# frozen_string_literal: true

require "application_system_test_case"

# Removing a scenario from the plan page and the map
# ([#439](https://github.com/espaliahq/espalia/issues/439)). The editor here
# can't see pay, so the dialog tells them, by count alone, what pay goes too.
class PlanRemoveScenarioSystemTest < ApplicationSystemTestCase
  AMOUNT = "92417"
  SECTION = "details[data-removed-scenarios]"

  setup do
    @tenant = create(:tenant)
    ActsAsTenant.with_tenant(@tenant) do
      holder = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @editor = create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant, name: "Erin Editor"))
      @viewer = create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant))
      ada = create(:person, tenant: @tenant, name: "Ada Quill")
      OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
                              .record_person(ada.id, provider: "espalia", effective_on: (Date.current - 30).iso8601, employment_status: "employed", level: "3")
      @plan_id = call(Operations::TeamPlanning::CreatePlan, holder, name: "Next year", base_on: (Date.current + 1).iso8601)[:plan_id]
      call(Operations::TeamPlanning::AddPlanMember, holder, plan_id: @plan_id, person_id: @editor.person_id, role: "editor")
      call(Operations::TeamPlanning::AddPlanMember, holder, plan_id: @plan_id, person_id: @viewer.person_id, role: "viewer")
      @q1 = call(Operations::TeamPlanning::ForkScenario, holder, plan_id: @plan_id, relation: "then", name: "Q1",
                                                                 ends_on: (Date.current + 120).iso8601)[:scenario_id]
      @q2 = call(Operations::TeamPlanning::ForkScenario, holder, plan_id: @plan_id, parent_id: @q1, relation: "then", name: "Q2")[:scenario_id]
      call(Operations::TeamPlanning::SetActualPay, holder, plan_id: @plan_id, scenario_id: @q2, person_id: ada.id,
                                                           amount: AMOUNT, currency: "AUD", period: "year", basis: "full_time")
    end
  end

  [ [ "desktop", DESKTOP_SIZE ], [ "phone", MOBILE_SIZE ] ].each do |label, size|
    context "on a #{label}" do
      setup { page.driver.browser.manage.window.resize_to(*size) }

      should "remove a scenario from its row, counting the pay it can't show, and land on the removal" do
        sign_in_as(@editor.user)
        visit plan_path(@plan_id)
        assert_selector "h1", text: "Next year"
        row = "tr[data-scenario-id='#{@q2}']"
        scroll_to(find(row), align: :center) # the menu opens fixed under its trigger, off a phone's screen below the fold
        open_dropdown(scope: row)
        click_button_with_js_fallback("Remove…", expect_text: "Remove Q2?")

        within("#remove-scenario-#{@q2}") do
          assert_text "Its 1 change goes with it. It can't be restored, and it will be listed under Removed scenarios."
          assert_text "This scenario holds 1 change to pay or budget amounts you can't see. Removing it removes that too."
        end
        assert_no_text AMOUNT
        assert_no_sideways_overflow
        click_button_with_js_fallback("Remove scenario", expect_text: "Removed Q2.")

        assert_selector "#{SECTION}[open] [data-removed-scenario='#{@q2}']", text: "Q2 · "
        assert_selector "#{SECTION} [data-removed-scenario='#{@q2}']", text: "1 change · removed by Erin Editor"
        assert_no_selector "tr[data-scenario-id='#{@q2}']"
      end

      should "explain from the map why a scenario others fork from can't be removed yet" do
        sign_in_as(@editor.user)
        visit map_plan_path(@plan_id, scenario: @q1)
        assert_selector "h1", text: "Next year"
        click_button_with_js_fallback("Remove…", expect_text: "Q1 can't be removed yet")

        within("#remove-scenario-#{@q1}") do
          assert_text "1 scenario forks from it: Q2. Remove that first."
          assert_no_button "Remove scenario"
        end
        assert_no_sideways_overflow
      end

      should "remove the scenario the map shows" do
        sign_in_as(@editor.user)
        visit map_plan_path(@plan_id, scenario: @q2)
        assert_selector "h1", text: "Next year"
        if label == "phone"
          picker_bottom, remove_top = evaluate_script(<<~JS)
            [document.getElementById("map-scenario").getBoundingClientRect().bottom,
             document.querySelector("button[data-modal-target-id='remove-scenario-#{@q2}']").getBoundingClientRect().top]
          JS
          assert_operator picker_bottom, :<=, remove_top, "the phone's scenario picker should keep its own line above Edit… and Remove…"
        end
        click_button_with_js_fallback("Remove…", expect_text: "Remove Q2?")
        click_button_with_js_fallback("Remove scenario", expect_text: "Removed Q2.")

        assert_selector "#{SECTION}[open] [data-removed-scenario='#{@q2}']"
      end
    end
  end

  should "offer a viewer no Remove" do
    sign_in_as(@viewer.user)
    visit plan_path(@plan_id)
    assert_selector "h1", text: "Next year"
    assert_no_selector "[data-modal-target-id^='remove-scenario-']", visible: :all

    visit map_plan_path(@plan_id, scenario: @q2)
    assert_selector "h1", text: "Next year"
    assert_no_button "Remove…"
  end

  private

  def call(operation, account, **params)
    operation.call(context: AuthorizationContext.new(user: account.user, tenant_user: account, person: account.person), params:)
  end
end
