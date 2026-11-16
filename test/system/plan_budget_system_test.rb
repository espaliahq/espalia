# frozen_string_literal: true

require "application_system_test_case"

class PlanBudgetSystemTest < ApplicationSystemTestCase
  setup do
    @tenant = create(:tenant)
    starts_on = Date.current + 1
    ActsAsTenant.with_tenant(@tenant) do
      @planner = account(team_planner: true, name: "Erin Editor")
      engineer = create(:framework_role, tenant: @tenant, name: "Software Engineer")
      @e2 = create(:framework_level, tenant: @tenant, role_id: engineer.role_id, ordinal: 2, title: "Engineer II")
      PayBand.create!(level: @e2, currency: "EUR", period: "year", minimum: 0, midpoint: 73_000, maximum: 100_000)
      ReferenceCurrency.create!(currency: "EUR")
      @line = BudgetLine.create!(starts_on:, ends_on: starts_on + 364, origin: "new", amount: 73_000, currency: "EUR", period: "year",
                                 head_count: 1, cost_centre: "Platform")
    end
    @plan_id = call(Operations::TeamPlanning::CreatePlan, @planner, name: "Pay review 2027", base_on: starts_on.iso8601)[:plan_id]
    @q1 = call(Operations::TeamPlanning::ForkScenario, @planner, plan_id: @plan_id, relation: "then", name: "Q1 hires",
                                                                 ends_on: (starts_on + 89).iso8601)[:scenario_id]
    2.times do
      call(Operations::TeamPlanning::SetPosition, @planner, plan_id: @plan_id, scenario_id: @q1, role_id: @e2.role_id, level_id: @e2.level_id,
                                                            unit_id: SecureRandom.uuid_v7, fte: 1, basis: "new", cost_centre: "Platform")
    end
  end

  context "on a desktop" do
    setup { page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE) }

    should "read the approved lines on Today, then a scenario's numbers with an over line's positions open" do
      sign_in_as(@planner.user)
      visit plan_path(@plan_id)
      click_link_with_js_fallback("Budget", expect_text: "Budget on Today")
      within("[data-budget-line='#{@line.id}']") { assert_text "EUR 73,000 a year · Head count 1" }

      click_selector_with_js_fallback("[data-budget-today] a[href='#{budget_plan_path(@plan_id, scenario: @q1)}']", expect_text: "Budget on Q1 hires")
      assert_equal %w[Approved Funded Remaining Unfunded], all("[data-budget-total] dt").map(&:text)
      within("[data-budget-line='#{@line.id}']") do
        assert_text "Over"
        assert_selector "details[open][data-budget-draws] [data-budget-draw]", count: 2
      end
      assert_no_sideways_overflow
    end
  end

  context "on a phone" do
    setup { page.driver.browser.manage.window.resize_to(*MOBILE_SIZE) }

    should "pick the scenario from a list and read its budget without scrolling sideways" do
      sign_in_as(@planner.user)
      visit budget_plan_path(@plan_id)
      assert_text "Budget on Today"
      assert page.evaluate_script(<<~JS), "every plan tab, the open one included, is on screen"
        [...document.querySelectorAll("nav[aria-label='Plan views'] a")].every((tab) => tab.getBoundingClientRect().right <= innerWidth)
      JS

      select "· Q1 hires", from: "budget-scenario"
      assert_text "Budget on Q1 hires"
      assert_selector "[data-budget-total]", count: 4
      assert_selector "details[open][data-budget-draws]"
      assert_no_sideways_overflow
    end
  end

  private

  def account(role: :member, name: "Someone", **grants)
    user = create(:user, password: TEST_PASSWORD)
    person = create(:person, tenant: @tenant, name:, email: user.email)
    create(:tenant_user, tenant: @tenant, user:, role:, person:, **grants)
  end

  def call(operation, account, **params)
    ActsAsTenant.with_tenant(@tenant) do
      operation.call(context: AuthorizationContext.new(user: account.user, tenant_user: account, person: account.person), params:)
    end
  end
end
