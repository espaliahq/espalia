# frozen_string_literal: true

require "application_system_test_case"

# Fork, edit and switch scenarios from a plan's page (#271, #272).
class PlanScenariosSystemTest < ApplicationSystemTestCase
  FORK = "##{Views::Plans::ScenarioDialogs::FORK_ID}".freeze
  EDIT = "##{Views::Plans::ScenarioDialogs::EDIT_ID}".freeze

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
          assert_no_field "Starts on"
          js_fill_in "Name", with: "Lean Q1"
          js_fill_in "Ends on", with: "2027-09-30"
        end
        click_button_with_js_fallback("Create scenario", expect_text: "Lean Q1 forked.")

        assert_text "with this scenario's changes"
        assert_no_sideways_overflow
      end

      should "let an editor start the first step after the base date, and show Today carrying on until then" do
        fresh = ActsAsTenant.with_tenant(@tenant) { call(Operations::TeamPlanning::CreatePlan, @planner, name: "Hiring 2027", base_on: "2026-11-14")[:plan_id] }
        sign_in_as(@planner.user)
        visit plan_path(fresh)
        assert_selector "h1", text: "Hiring 2027"
        open_dialog("New scenario", FORK)

        within(FORK) do
          assert_equal "2026-11-14", find_field("Starts on").value
          js_fill_in "Name", with: "Q1 hires"
          js_fill_in "Starts on", with: "2026-12-01"
          js_fill_in "Ends on", with: "2027-03-31"
        end
        click_button_with_js_fallback("Create scenario", expect_text: "Q1 hires forked.")

        visit plan_path(fresh)
        assert_selector "tr[data-scenario-id='#{fresh}'] [data-today-continues='2026-11-30']", text: "Today continues to 30 Nov 2026"
        assert_no_sideways_overflow
        visit timeline_plan_path(fresh)
        assert_selector "[data-today-continues='2026-11-30']", text: "Today continues to 30 Nov 2026"
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

      should "let an editor rename and describe a scenario from its menu, and edit it from its map" do
        sign_in_as(@planner.user)
        visit plan_path(@plan_id)
        assert_selector "h1", text: "Pay review 2027"
        row_action(@q1, Views::Plans::ScenarioDialogs::EDIT_ID)

        within(EDIT) do
          assert_equal "Q1 hires", find_field("Name").value
          assert_equal "", find_field("Description").value
          js_fill_in "Name", with: "Lean Q1"
          js_fill_in "Description", with: "Hire two seniors before Q3"
        end
        click_button_with_js_fallback("Save", expect_text: "Saved Lean Q1.")
        within("table") do
          assert_text "then Lean Q1"
          assert_text "Hire two seniors before Q3"
        end

        visit map_plan_path(@plan_id, scenario: @q1)
        assert_text "with this scenario's changes"
        open_dialog("Edit…", EDIT)
        within(EDIT) do
          assert_equal "Hire two seniors before Q3", find_field("Description").value
          js_fill_in "Name", with: "Q1 hiring"
        end
        click_button_with_js_fallback("Save", expect_text: "Saved Q1 hiring.")
        assert_current_path map_plan_path(@plan_id, scenario: @q1)
        assert_no_sideways_overflow
      end

      should "show a viewer a scenario's description, and no way to fork or edit" do
        ActsAsTenant.with_tenant(@tenant) do
          call(Operations::TeamPlanning::DescribeScenario, @planner, plan_id: @plan_id, scenario_id: @q1, description: "Hire two seniors before Q3")
        end
        sign_in_as(@viewer.user)
        visit plan_path(@plan_id)
        assert_selector "h1", text: "Pay review 2027"
        assert_no_button "New scenario"
        assert_no_selector "[aria-label^='Actions for']"
        within("table") { assert_text "Hire two seniors before Q3" }

        visit map_plan_path(@plan_id, scenario: @q1)
        assert_text "with this scenario's changes"
        assert_no_button "Edit…"
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

  should "close the edit dialog on Esc, asking first only about text typed since it opened" do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    ActsAsTenant.with_tenant(@tenant) do
      call(Operations::TeamPlanning::DescribeScenario, @planner, plan_id: @plan_id, scenario_id: @q1, description: "Hire two seniors")
    end
    sign_in_as(@planner.user)
    visit plan_path(@plan_id)
    assert_selector "h1", text: "Pay review 2027"
    page.execute_script("window.confirm = () => false")

    row_action(@q1, Views::Plans::ScenarioDialogs::EDIT_ID)
    press_escape(scope: EDIT)
    assert_no_selector EDIT, visible: true

    row_action(@q1, Views::Plans::ScenarioDialogs::EDIT_ID)
    js_fill_in "Description", with: "Hire three seniors"
    press_escape(scope: EDIT)
    assert_selector EDIT, visible: true
  end

  should "reopen a row menu toggled in the same moment it closed" do
    sign_in_as(@planner.user)
    visit plan_path(@plan_id)
    row = "tr[data-scenario-id='#{@q1}']"
    wait_for_stimulus "dropdown", scope: row

    page.execute_script(<<~JS, find("#{row} [data-action='dropdown#toggle']"))
      const trigger = arguments[0]
      trigger.click()
      window.dispatchEvent(new CustomEvent("modal:open"))
      trigger.click()
    JS

    assert_selector "#{row} [data-action='dropdown#toggle'][aria-expanded='true']"
    hidden_after_frames = page.evaluate_async_script(<<~JS, find("#{row} [data-dropdown-target='menu']", visible: :all))
      const [menu, done] = arguments
      requestAnimationFrame(() => requestAnimationFrame(() => setTimeout(() => done(menu.hidden))))
    JS
    assert_not hidden_after_frames, "the menu hid a few frames after it opened"
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
