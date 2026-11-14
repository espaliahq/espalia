# frozen_string_literal: true

require "application_system_test_case"

# Fork, rename and switch scenarios from a plan's page (#271).
class PlanScenariosSystemTest < ApplicationSystemTestCase
  FORK = "##{Views::Plans::ScenarioDialogs::FORK_ID}".freeze
  RENAME = "##{Views::Plans::ScenarioDialogs::RENAME_ID}".freeze

  setup do
    @tenant = create(:tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @planner = account(team_planner: true, name: "Erin Editor")
      @viewer = account(name: "Vic Viewer")
      @plan_id = call(Operations::TeamPlanning::CreatePlan, @planner, name: "Pay review 2027", base_on: "2026-11-14")[:plan_id]
      call(Operations::TeamPlanning::AddPlanMember, @planner, plan_id: @plan_id, person_id: @viewer.person.id, role: "viewer")
      @q1 = call(Operations::TeamPlanning::ForkScenario, @planner, plan_id: @plan_id, relation: "then", name: "Q1 hires",
                                                                   ends_on: "2027-03-31")[:scenario_id]
      @q2 = call(Operations::TeamPlanning::ForkScenario, @planner, plan_id: @plan_id, parent_id: @q1, relation: "then", name: "Q2 hires",
                                                                   ends_on: "2027-06-30")[:scenario_id]
    end
  end

  [ [ "desktop", DESKTOP_SIZE ], [ "phone", MOBILE_SIZE ] ].each do |label, size|
    context "on a #{label}" do
      setup { page.driver.browser.manage.window.resize_to(*size) }

      should "let an editor carry the plan on from the header, and land on the new scenario's map" do
        sign_in_as(@planner.user)
        visit plan_path(@plan_id)
        assert_selector "h1", text: "Pay review 2027"
        open_dialog("New scenario", FORK)

        within(FORK) do
          assert_equal @q2, find_field("Starts from").value
          assert find_field("After it", checked: true)
          js_fill_in "Name", with: "Lean Q1"
          js_fill_in "Ends on", with: "2027-09-30"
        end
        click_button_with_js_fallback("Create scenario", expect_text: "Lean Q1 forked.")

        assert_text "with this scenario's changes"
        assert_no_sideways_overflow
      end

      should "let an editor fork an alternative from a scenario's menu" do
        sign_in_as(@planner.user)
        visit plan_path(@plan_id)
        assert_selector "h1", text: "Pay review 2027"
        row_action(@q1, Views::Plans::ScenarioDialogs::FORK_ID)

        within(FORK) do
          assert_equal @q1, find_field("Starts from").value
          # Q1 hires already has Q2 hires after it, so only an alternative is left.
          assert find_field("After it", disabled: true)
          assert find_field("Instead of it", checked: true)
          assert_no_field "Ends on"
          js_fill_in "Name", with: "Slower hiring"
        end
        click_button_with_js_fallback("Create scenario", expect_text: "Slower hiring forked.")

        visit plan_path(@plan_id)
        within("table") { assert_text "instead Slower hiring" }
      end

      should "explain why nothing more can start from today" do
        sign_in_as(@planner.user)
        visit plan_path(@plan_id)
        assert_selector "h1", text: "Pay review 2027"
        row_action(@plan_id, Views::Plans::ScenarioDialogs::FORK_ID)

        within(FORK) do
          assert_text "Today already has a scenario after it"
          assert_button "Create scenario", disabled: true
        end
      end

      should "let an editor rename a scenario from its menu and from its map" do
        sign_in_as(@planner.user)
        visit plan_path(@plan_id)
        assert_selector "h1", text: "Pay review 2027"
        row_action(@q1, Views::Plans::ScenarioDialogs::RENAME_ID)

        within(RENAME) do
          assert_equal "Q1 hires", find_field("Name").value
          js_fill_in "Name", with: "Lean Q1"
        end
        click_button_with_js_fallback("Save", expect_text: "Renamed to Lean Q1.")
        within("table") { assert_text "then Lean Q1" }

        visit map_plan_path(@plan_id, scenario: @q1)
        assert_text "with this scenario's changes"
        open_dialog("Rename…", RENAME)
        within(RENAME) do
          js_fill_in "Name", with: "Q1 hiring"
        end
        click_button_with_js_fallback("Save", expect_text: "Renamed to Q1 hiring.")
        assert_current_path map_plan_path(@plan_id, scenario: @q1)
        assert_no_sideways_overflow
      end

      should "show a viewer no way to fork or rename" do
        sign_in_as(@viewer.user)
        visit plan_path(@plan_id)
        assert_selector "h1", text: "Pay review 2027"
        assert_no_button "New scenario"
        assert_no_selector "[aria-label^='Actions for']"

        visit map_plan_path(@plan_id, scenario: @q1)
        assert_text "with this scenario's changes"
        assert_no_button "Rename…"
      end
    end
  end

  should "switch scenarios from the pills on a desktop" do
    sign_in_as(@viewer.user)
    visit map_plan_path(@plan_id)
    assert_no_selector "select#map-scenario", visible: true
    within("nav[aria-label='Scenario']") do
      click_link_with_js_fallback("Q2 hires", expect_selector: "a[aria-current='page'][href$='#{@q2}']")
    end
  end

  should "switch scenarios from a list on a phone" do
    page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
    sign_in_as(@viewer.user)
    visit map_plan_path(@plan_id)
    assert_no_selector "nav[aria-label='Scenario']", visible: true
    wait_for_stimulus "auto-submit"

    page.execute_script(<<~JS)
      const select = document.getElementById("map-scenario")
      select.value = select.querySelector("option:nth-child(3)").value
      select.dispatchEvent(new Event("change", { bubbles: true }))
    JS
    assert_text "with this scenario's changes"
    assert_equal "· · Q2 hires", find("select#map-scenario").find("option[selected]").text
    assert_no_sideways_overflow
  end

  should "close the dialogs on Esc, asking first once the new scenario has a name" do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    sign_in_as(@planner.user)
    visit plan_path(@plan_id)
    assert_selector "h1", text: "Pay review 2027"
    open_dialog("New scenario", FORK)
    press_escape(scope: FORK)
    assert_no_selector FORK, visible: true

    open_dialog("New scenario", FORK)
    js_fill_in "Name", with: "Lean Q1"
    page.execute_script("window.confirm = () => false")
    press_escape(scope: FORK)
    assert_selector FORK, visible: true

    page.execute_script("window.confirm = () => true")
    press_escape(scope: FORK)
    assert_no_selector FORK, visible: true
  end

  private

  def open_dialog(button, dialog)
    wait_for_stimulus "modal"
    click_button_with_js_fallback(button, expect_selector: dialog)
  end

  def row_action(scenario_id, dialog_id)
    row = "tr[data-scenario-id='#{scenario_id}']"
    open_dropdown(scope: row)
    click_selector_with_js_fallback("#{row} [role='menuitem'][data-modal-target-id='#{dialog_id}']", expect_selector: "##{dialog_id}")
  end

  def account(role: :member, name: "Someone", **grants)
    user = create(:user, password: TEST_PASSWORD)
    person = create(:person, tenant: @tenant, name:, email: user.email)
    create(:tenant_user, tenant: @tenant, user:, role:, person:, **grants)
  end

  def call(operation, account, **params)
    context = AuthorizationContext.new(user: account.user, tenant_user: account, person: account.person)
    operation.call(context:, params:)
  end
end
