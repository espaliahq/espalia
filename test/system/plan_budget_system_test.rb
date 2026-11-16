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

    should "add and change a line, split a position's funding, send it back to the derived line, then cut the line" do
      sign_in_as(@planner.user)
      visit budget_plan_path(@plan_id, scenario: @q1)
      add_and_change_lines
      split_funding
      assert_text "Open · 50% of it · 0.5 FTE"
      assert_selector "[data-budget-draw]", count: 3, visible: :all
      assert_no_stolen_taps

      clear_funding
      cut_line(growth_line_id)
    end

    should "show a viewer without the see-pay right head counts and no money" do
      read_without_money
    end

    should "let an editor without the see-pay right add and change lines by head count, and keep a priced line's form shut" do
      edit_without_money
    end

    should "tell a scoped plan's reader the totals cover only its lines, and show no other" do
      payments = SecureRandom.uuid_v7
      field_sales = nil
      ActsAsTenant.with_tenant(@tenant) do
        structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
        departments = SecureRandom.uuid_v7
        structure.define_taxonomy([ { level_id: departments, name: "Department" } ], effective_on: "2025-01-01")
        structure.create_unit(payments, "Payments", level_id: departments, effective_on: "2025-01-01")
        ada = create(:person, tenant: @tenant, name: "Ada Quill")
        people = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
        people.record_person(ada.id, provider: "espalia", effective_on: "2025-01-01", employment_status: "employed", title: "Engineer", fte: 1.0)
        people.set_membership(ada.id, payments, provider: "espalia", effective_on: "2025-01-01", allocation: 1.0)
        people.change_cost_centre(ada.id, "Platform", provider: "espalia", effective_on: "2025-01-01")
        field_sales = BudgetLine.create!(starts_on: @line.starts_on, ends_on: @line.ends_on, origin: "new", amount: 51_000, currency: "EUR",
                                         period: "year", cost_centre: "Field Sales")
      end
      scoped = call(Operations::TeamPlanning::CreatePlan, @planner, name: "Payments 2027", base_on: @line.starts_on.iso8601, unit_ids: [ payments ])[:plan_id]

      sign_in_as(@planner.user)
      visit budget_plan_path(scoped)
      assert_text "Totals cover the budget lines this plan's seats can draw on."
      assert_selector "[data-budget-line='#{@line.id}']"
      assert_no_selector "[data-budget-line='#{field_sales.id}']"
      assert_no_text "Field Sales"

      visit budget_plan_path(@plan_id)
      assert_selector "[data-budget-line='#{field_sales.id}']"
      assert_no_text "Totals cover the budget lines"
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

    should "show a viewer without the see-pay right head counts and no money" do
      read_without_money
    end

    should "let an editor without the see-pay right add and change lines by head count, and keep a priced line's form shut" do
      edit_without_money
    end

    should "add and change a line, split a position's funding, send it back to the derived line, then cut the line" do
      sign_in_as(@planner.user)
      visit budget_plan_path(@plan_id, scenario: @q1)
      add_and_change_lines
      assert_no_sideways_overflow
      split_funding
      assert_no_sideways_overflow
      clear_funding
      cut_line(growth_line_id)
      assert_no_sideways_overflow
    end
  end

  private

  # A budget amount is pay ([#367](https://github.com/espaliahq/espalia/issues/367)).
  def read_without_money
    viewer = ActsAsTenant.with_tenant(@tenant) { account(name: "Vic Viewer") }
    call(Operations::TeamPlanning::AddPlanMember, @planner, plan_id: @plan_id, person_id: viewer.person_id, role: "viewer")

    sign_in_as(viewer.user)
    visit budget_plan_path(@plan_id)
    assert_text "Budget on Today"
    assert_text "Budget amounts show only to members who may see pay."
    within("[data-budget-line='#{@line.id}']") { assert_text "Head count 1" }

    visit budget_plan_path(@plan_id, scenario: @q1)
    assert_text "Budget on Q1 hires"
    assert_equal [ "Head count 1", "2 positions, 2 FTE", "Head count -1", "0 positions, 0 FTE" ], all("[data-budget-total] dd").map(&:text)
    [ "EUR", "73,000", "No amount" ].each { assert_no_text it }
    assert_no_sideways_overflow
  end

  def edit_without_money
    editor = ActsAsTenant.with_tenant(@tenant) { account(name: "Eli Editor") }
    call(Operations::TeamPlanning::AddPlanMember, @planner, plan_id: @plan_id, person_id: editor.person_id, role: "editor")

    sign_in_as(editor.user)
    visit budget_plan_path(@plan_id, scenario: @q1)
    assert_text "Budget on Q1 hires"
    click_link_with_js_fallback("Add a line", expect_text: "Add a budget line to Q1 hires")
    [ "budget-line-amount", "budget-line-currency", "budget-line-period" ].each { assert_no_field it }
    js_fill_in "budget-line-starts-on", with: @line.starts_on.iso8601
    js_fill_in "budget-line-ends-on", with: @line.ends_on.iso8601
    js_fill_in "budget-line-head-count", with: "3"
    js_fill_in "budget-line-cost-centre", with: "Support"
    assert_no_sideways_overflow
    click_button_with_js_fallback("Add the line", expect_text: "Budget line added.")
    added = find("[data-budget-line]", text: "Cost centre Support")["data-budget-line"]

    click_selector_with_js_fallback("a[href='#{edit_budget_line_plan_path(@plan_id, budget_line_id: @line.id, scenario: @q1)}']",
                                    expect_text: "Changing this budget line needs the see-pay right.")
    assert_no_selector "[data-budget-line-form]"

    click_selector_with_js_fallback("a[href='#{edit_budget_line_plan_path(@plan_id, budget_line_id: added, scenario: @q1)}']",
                                    expect_selector: "[data-budget-line-form='#{added}']")
    assert_no_field "budget-line-amount"
    js_fill_in "budget-line-head-count", with: "4"
    click_button_with_js_fallback("Save the line", expect_text: "Budget line changed.")
    within("[data-budget-line='#{added}']") { assert_text "Head count 4" }
    [ "EUR", "73,000" ].each { assert_no_text it }
  end

  def add_and_change_lines
    click_link_with_js_fallback("Add a line", expect_text: "Add a budget line to Q1 hires")
    js_fill_in "budget-line-starts-on", with: @line.starts_on.iso8601
    js_fill_in "budget-line-ends-on", with: @line.ends_on.iso8601
    js_fill_in "budget-line-amount", with: "40,000"
    js_fill_in "budget-line-currency", with: "EUR"
    js_fill_in "budget-line-cost-centre", with: "Growth"
    click_button_with_js_fallback("Add the line", expect_text: "Budget line added.")
    assert_text "Cost centre Growth"

    click_selector_with_js_fallback("a[href='#{edit_budget_line_plan_path(@plan_id, budget_line_id: @line.id, scenario: @q1)}']",
                                    expect_selector: "[data-budget-line-form='#{@line.id}']")
    js_fill_in "budget-line-head-count", with: "2"
    click_button_with_js_fallback("Save the line", expect_text: "Budget line changed.")
    within("[data-budget-line='#{@line.id}']") { assert_text "head count 2" }
  end

  def clear_funding
    open_funding
    click_button_with_js_fallback("Clear the funding", expect_text: "Funding goes back to the line the plan finds.")
    assert_no_text "Open · 50% of it"
  end

  def growth_line_id = find("[data-budget-line]", text: "Cost centre Growth")["data-budget-line"]

  def open_funding
    wait_for_stimulus "modal"
    trigger = find("[data-budget-line='#{@line.id}'] [data-funding-action]", match: :first)
    click_selector_with_js_fallback("[data-funding-action='#{trigger['data-funding-action']}']", expect_selector: "#funding-modal")
  end

  def split_funding
    open_funding
    within("#funding-modal") do
      js_fill_in "funding[parts][#{@line.id}]", with: "50"
      js_fill_in find("input[name^='funding[parts]']:not([name$='[#{@line.id}]'])"), with: "50"
    end
    click_button_with_js_fallback("Save funding", expect_text: "Funding set.")
  end

  def cut_line(budget_line_id)
    click_selector_with_js_fallback("a[href='#{edit_budget_line_plan_path(@plan_id, budget_line_id:, scenario: @q1)}']",
                                    expect_selector: "[data-budget-line-form='#{budget_line_id}']")
    wait_for_stimulus "modal"
    click_button_with_js_fallback("budget-line-cut-open", expect_selector: "#budget-line-cut")
    click_selector_with_js_fallback("#budget-line-cut button[type='submit']", expect_text: "Budget line cut.")
    assert_no_selector "[data-budget-line='#{budget_line_id}']"
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
