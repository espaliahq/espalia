# frozen_string_literal: true

require "application_system_test_case"

class PlanChecksSystemTest < ApplicationSystemTestCase
  ESPALIA = { provider: "espalia" }.freeze

  setup do
    @tenant = create(:tenant)
    handler = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    team = SecureRandom.uuid_v7
    payments = SecureRandom.uuid_v7
    @growth = SecureRandom.uuid_v7

    travel_to(30.days.ago) do
      since = Date.current.iso8601
      ActsAsTenant.with_tenant(@tenant) do
        @planner = account(team_planner: true, name: "Erin Editor")
        @bo = create(:person, tenant: @tenant, name: "Bo Reyes")
        structure.define_taxonomy([ { level_id: team, name: "Team" } ], effective_on: since)
        structure.create_unit(payments, "Payments", level_id: team, effective_on: since)
        structure.create_unit(@growth, "Growth", level_id: team, effective_on: since)
        handler.record_person(@bo.id, **ESPALIA, effective_on: since, employment_status: "employed")
        handler.set_membership(@bo.id, payments, **ESPALIA, effective_on: since, allocation: 1.0, role: "ENG")
      end
      @plan_id = call(Operations::TeamPlanning::CreatePlan, @planner, name: "Pay review 2027", base_on: (Date.current + 1).iso8601)[:plan_id]
    end
    @q1 = call(Operations::TeamPlanning::ForkScenario, @planner, plan_id: @plan_id, relation: "then", name: "Q1 hires",
                                                                 ends_on: (Date.current + 120).iso8601)[:scenario_id]
    call(Operations::TeamPlanning::SetAssignment, @planner, plan_id: @plan_id, scenario_id: @q1, person_id: @bo.id,
                                                            placements: [ { unit_id: @growth, allocation: 1, role: "ENG" } ])
    call(Operations::TeamPlanning::RetireUnit, @planner, plan_id: @plan_id, scenario_id: @plan_id, unit_id: @growth)
  end

  context "on a desktop" do
    setup { page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE) }

    should "group what no longer fits by check, and follow an item to the change behind it" do
      sign_in_as(@planner.user)
      visit plan_path(@plan_id)
      click_link_with_js_fallback("Checks", expect_text: "Checks on Today")
      within("#checks-managers") { assert_selector "[data-check-item]", text: /Bo Reyes · Manager.*Has no manager.*Nothing in the plan explains it/m }

      click_selector_with_js_fallback("nav[aria-label='Scenario'] a[href='#{checks_plan_path(@plan_id, scenario: @q1)}']",
                                      expect_text: "Checks on Q1 hires")
      within("#checks-placements") do
        assert_selector "h4", text: "Placements"
        assert_selector "[data-check-item]", text: /Bo Reyes · Placement.*Placed in a retired unit.*From a change in Q1 hires.*Source: Espalia/m
      end
      assert_equal [ "Placements 1", "Managers 1" ], all("nav[aria-label='Checks'] a").map { it.text.squish }
      assert_no_sideways_overflow

      click_selector_with_js_fallback("#checks-placements [data-check-item] a", expect_text: "Planned in Q1 hires")
      assert page.evaluate_script("document.getElementById(location.hash.slice(1))?.matches('[data-planned-change]') ?? false"),
             "the link lands on the change's row"

      within("[data-changes-section='attention']") { assert_text "2 items in Q1 hires no longer fit." }
      click_link_with_js_fallback("Review them in Checks", expect_text: "Checks on Q1 hires")
      assert_selector "#checks-placements [data-check-item]", text: "Placed in a retired unit"
    end

    should "list a budget line nothing draws on under its own heading, with no amount" do
      idle_line
      sign_in_as(@planner.user)
      visit checks_plan_path(@plan_id, scenario: @q1)
      assert_text "Checks on Q1 hires"

      within("#checks-unused-budget-lines") do
        assert_selector "h4", text: "Unused budget lines"
        assert_selector "[data-check-item]", text: /Any role · Growth.*Nothing in this scenario draws on it/m
        assert_no_text "90,000"
      end
      assert_includes all("nav[aria-label='Checks'] a").map { it.text.squish }, "Unused budget lines 1"
      assert_no_sideways_overflow
    end
  end

  context "on a phone" do
    setup { page.driver.browser.manage.window.resize_to(*MOBILE_SIZE) }

    should "pick the scenario from a list and read its checks without scrolling sideways" do
      sign_in_as(@planner.user)
      visit checks_plan_path(@plan_id)
      assert_text "Checks on Today"
      assert_no_selector "nav[aria-label='Scenario']", visible: true
      assert page.evaluate_script(<<~JS), "every plan tab, the open one included, is on screen"
        [...document.querySelectorAll("nav[aria-label='Plan views'] a")].every((tab) => tab.getBoundingClientRect().right <= innerWidth)
      JS

      select "· Q1 hires", from: "checks-scenario"
      assert_text "Checks on Q1 hires"
      assert_selector "#checks-placements [data-check-item]", text: "Placed in a retired unit"
      assert_no_sideways_overflow
    end

    should "read a budget line nothing draws on without scrolling sideways" do
      idle_line
      sign_in_as(@planner.user)
      visit checks_plan_path(@plan_id, scenario: @q1)
      assert_text "Checks on Q1 hires"

      assert_selector "#checks-unused-budget-lines [data-check-item]", text: /Any role · Growth.*Nothing in this scenario draws on it/m
      assert_no_sideways_overflow
    end
  end

  private

  def idle_line
    ActsAsTenant.with_tenant(@tenant) do
      BudgetLine.create!(starts_on: Date.current - 60, ends_on: Date.current + 300, origin: "new", amount: 90_000, currency: "AUD",
                         period: "year", cost_centre: "Growth")
    end
  end

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
