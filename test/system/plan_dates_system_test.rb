# frozen_string_literal: true

require "application_system_test_case"

# Change a step's dates from the plan page and the map
# ([#404](https://github.com/espaliahq/espalia/issues/404)).
class PlanDatesSystemTest < ApplicationSystemTestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @planner = account(team_planner: true, name: "Erin Editor")
      ReferenceCurrency.create!(currency: "EUR")
      teams = SecureRandom.uuid_v7
      payments = SecureRandom.uuid_v7
      structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
      structure.define_taxonomy([ { level_id: teams, name: "Team" } ], effective_on: "2026-01-01")
      structure.create_unit(payments, "Payments", level_id: teams, effective_on: "2026-01-01")
      engineer = create(:framework_role, code: "E", name: "Software Engineer")
      senior = create(:framework_level, role_id: engineer.role_id, ordinal: 5, title: "Senior SWE")
      add_pay_band!(level: senior, currency: "EUR", period: "year", minimum: 80_000, midpoint: 100_000, maximum: 120_000)
      @plan_id = call(Operations::TeamPlanning::CreatePlan, name: "Next year", base_on: "2026-11-14")[:plan_id]
      @q1 = call(Operations::TeamPlanning::ForkScenario, plan_id: @plan_id, relation: "then", name: "Q1 hires", ends_on: "2027-03-31")[:scenario_id]
      @q2 = call(Operations::TeamPlanning::ForkScenario, plan_id: @plan_id, parent_id: @q1, relation: "then", name: "Q2 settle",
                                                         ends_on: "2027-06-30")[:scenario_id]
      @position = ->(fte) do
        call(Operations::TeamPlanning::SetPosition, plan_id: @plan_id, scenario_id: @q1, role_id: engineer.role_id,
                                                    level_id: senior.level_id, unit_id: payments, fte:, basis: "new")
        call(Operations::TeamPlanning::History, plan_id: @plan_id, scenario_id: @q1)[:entries].last[:event_id]
      end
      @agreed_position = @position.(1)
    end
  end

  should "go back to the map of a split's rest after opening its agreed part's dates" do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    @position.(0.5)
    call(Operations::TeamPlanning::SplitScenario, plan_id: @plan_id, scenario_id: @q1, event_ids: [ @agreed_position ], name: "Agreed hires")
    sign_in_as(@planner.user)
    visit map_plan_path(@plan_id, scenario: @q1)
    assert_selector "h1", text: "Next year"

    click_link_with_js_fallback("Dates…", expect_text: "Dates for Agreed hires")
    click_link_with_js_fallback("Cancel", expect_text: "Q1 hires")
    assert_current_path map_plan_path(@plan_id, scenario: @q1)
  end

  [ [ "desktop", DESKTOP_SIZE ], [ "phone", MOBILE_SIZE ] ].each do |label, size|
    context "on a #{label}" do
      setup { page.driver.browser.manage.window.resize_to(*size) }

      should "preview new dates from the map, save them, and show the same period on the map and the scenarios table" do
        sign_in_as(@planner.user)
        visit map_plan_path(@plan_id, scenario: @q1)
        assert_selector "h1", text: "Next year"
        click_link_with_js_fallback("Dates…", expect_text: "Dates for Q1 hires")

        assert_no_sideways_overflow
        js_fill_in "Starts on", with: "2026-12-01"
        js_fill_in "Ends on", with: "2027-04-30"
        click_button_with_js_fallback("Preview", expect_text: "What this moves")
        assert_selector "[data-dates-move='#{@q2}']", text: "Q2 settle: Apr to Jun 2027, now May to Jun 2027."
        assert_no_sideways_overflow

        click_button_with_js_fallback("Save dates", expect_text: "Saved the dates of Q1 hires.")
        assert_current_path map_plan_path(@plan_id, scenario: @q1)
        assert_selector "[data-cost-strip]", text: "For 1 Dec 2026 to 30 Apr 2027"
        on_map = find("[data-cost-strip] [data-cost-total]").text

        visit plan_path(@plan_id)
        assert_selector "tr[data-scenario-id='#{@q1}']", text: "Dec 2026 to Apr 2027"
        assert_selector "[data-cost-cell='#{@q1}']", text: on_map
        assert_selector "tr[data-scenario-id='#{@q2}']", text: "May to Jun 2027"
      end
    end
  end

  [ [ "desktop", DESKTOP_SIZE ], [ "phone", MOBILE_SIZE ] ].each do |label, size|
    should "take the end off the last step on a #{label}, show its cost over the horizon, and keep an end on the step before it" do
      page.driver.browser.manage.window.resize_to(*size)
      sign_in_as(@planner.user)
      visit dates_plan_path(@plan_id, scenario_id: @q2)
      assert_selector "h3", text: "Dates for Q2 settle"

      js_set_checkbox "No end date", checked: true
      click_button_with_js_fallback("Preview", expect_text: "What this moves")
      assert_selector "[data-dates-preview='#{@q2}']", text: "Q2 settle: Apr to Jun 2027, now from 1 Apr 2027 · no end date."
      assert_no_sideways_overflow
      click_button_with_js_fallback("Save dates", expect_text: "Saved the dates of Q2 settle.")

      visit map_plan_path(@plan_id, scenario: @q2)
      assert_selector "[data-cost-strip]", text: "For 1 Apr 2027 to 31 Mar 2028, the first 12 months of a step with no end date"
      assert_selector "[data-cost-strip] [data-run-rate-at-end]", text: "Run rate on 31 Mar 2028, the end of the 12 months shown:"
      assert_no_sideways_overflow
      visit plan_path(@plan_id)
      assert_selector "tr[data-scenario-id='#{@q2}']", text: "From 1 Apr 2027 · no end date"

      visit dates_plan_path(@plan_id, scenario_id: @q2)
      assert_selector "[data-dates-current='#{@q2}']", text: "Now from 1 Apr 2027 · no end date."
      assert_selector "input[name='ends_on'][disabled]:not([required])"
      js_set_checkbox "No end date", checked: false
      assert_selector "input[name='ends_on'][required]:not([disabled])"

      visit dates_plan_path(@plan_id, scenario_id: @q1)
      assert_text "A step comes after this one, so it needs an end."
      assert_no_field "No end date"
    end
  end

  private

  def account(role: :member, name: "Someone", **grants)
    user = create(:user, password: TEST_PASSWORD)
    person = create(:person, tenant: @tenant, name:, email: user.email)
    create(:tenant_user, tenant: @tenant, user:, role:, person:, **grants)
  end

  def call(operation, **params)
    ActsAsTenant.with_tenant(@tenant) do
      context = AuthorizationContext.new(user: @planner.user, tenant_user: @planner, person: @planner.person)
      operation.call(context:, params:)
    end
  end
end
