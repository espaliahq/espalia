# frozen_string_literal: true

require "application_system_test_case"

# The removed scenarios under a plan's scenario tree (#340).
class PlanRemovedScenariosSystemTest < ApplicationSystemTestCase
  SECTION = "details[data-removed-scenarios]"

  setup do
    @tenant = create(:tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @planner = account(team_planner: true, name: "Erin Editor")
      @viewer = account(name: "Vic Viewer")
      @plan_id = call(Operations::TeamPlanning::CreatePlan, @planner, name: "Pay review 2027", base_on: "2026-11-14")[:plan_id]
      call(Operations::TeamPlanning::AddPlanMember, @planner, plan_id: @plan_id, person_id: @viewer.person.id, role: "viewer")
      @q1 = fork(name: "Q1 hires", ends_on: "2027-03-31")
      @q2 = fork(name: "Q2 hires", parent_id: @q1, ends_on: "2027-06-30")
    end
  end

  [ [ "desktop", DESKTOP_SIZE ], [ "phone", MOBILE_SIZE ] ].each do |label, size|
    context "on a #{label}" do
      setup { page.driver.browser.manage.window.resize_to(*size) }

      should "list a removed scenario on one line, closed until opened, for a viewer" do
        remove(@q2)
        sign_in_as(@viewer.user)
        visit plan_path(@plan_id)
        assert_selector "h1", text: "Pay review 2027"
        assert_selector "#{SECTION}:not([open]) summary", text: "Removed scenarios (1)"
        open_section

        within(SECTION) do
          assert_selector "[data-removed-scenario='#{@q2}']",
                          text: "Q2 hires · 1 Apr 2027 – 30 Jun 2027 · 0 changes · removed by Erin Editor on #{Date.current.strftime('%-d %b %Y')}"
        end
        assert_no_sideways_overflow
      end

      should "still list them once the plan is archived" do
        remove(@q2)
        ActsAsTenant.with_tenant(@tenant) { call(Operations::TeamPlanning::ArchivePlan, @planner, plan_id: @plan_id) }
        sign_in_as(@planner.user)
        visit plan_path(@plan_id)
        assert_text "Archived on"
        open_section

        assert_selector "#{SECTION} [data-removed-scenario='#{@q2}']", text: "Q2 hires"
      end
    end
  end

  should "wrap a long unbroken name on a phone rather than run off the side" do
    page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
    name = "Q3" + "x" * 80
    long = ActsAsTenant.with_tenant(@tenant) { fork(name:, parent_id: @q1, relation: "instead") }
    remove(long)
    sign_in_as(@viewer.user)
    visit plan_path(@plan_id)
    assert_selector "h1", text: "Pay review 2027"
    open_section

    assert_selector "#{SECTION} [data-removed-scenario='#{long}'] span", exact_text: name
    assert_no_sideways_overflow
    assert page.evaluate_script(<<~JS), "the name runs past the side of the page"
      [...document.querySelector("[data-removed-scenario='#{long}'] span").getClientRects()]
        .every((line) => line.right <= document.documentElement.clientWidth)
    JS
  end

  should "leave the section out while nothing has been removed" do
    sign_in_as(@viewer.user)
    visit plan_path(@plan_id)
    assert_selector "h1", text: "Pay review 2027"
    assert_text "Q2 hires"

    assert_no_selector SECTION, visible: :all
  end

  should "page through them, newest first, and stay open on each page" do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    lean = ActsAsTenant.with_tenant(@tenant) { fork(name: "Lean Q1", parent_id: @q1, relation: "instead") }
    remove(lean)
    travel 1.minute do
      remove(@q2)
    end

    Operations::TeamPlanning::RemovedScenarios.stub(:per_page, 1) do
      sign_in_as(@viewer.user)
      visit plan_path(@plan_id)
      assert_selector "h1", text: "Pay review 2027"
      open_section
      assert_selector "#{SECTION} summary", text: "Removed scenarios (2)"
      assert_selector "#{SECTION} [data-removed-scenario='#{@q2}']"

      click_link_with_js_fallback("Older", expect_selector: "#{SECTION}[open] [data-removed-scenario='#{lean}']")
      assert_no_selector "[data-removed-scenario='#{@q2}']"
      assert_selector "#{SECTION} a", text: "Newer"
    end
  end

  private

  def open_section = click_selector_with_js_fallback("#{SECTION} summary", expect_selector: "#{SECTION}[open]")

  def fork(name:, parent_id: nil, relation: "then", ends_on: nil)
    call(Operations::TeamPlanning::ForkScenario, @planner, plan_id: @plan_id, parent_id:, relation:, name:, ends_on:)[:scenario_id]
  end

  def remove(scenario_id)
    ActsAsTenant.with_tenant(@tenant) { call(Operations::TeamPlanning::RemoveScenario, @planner, plan_id: @plan_id, scenario_id:) }
  end

  def account(role: :member, name: "Someone", **grants)
    user = create(:user, password: TEST_PASSWORD)
    person = create(:person, tenant: @tenant, name:, email: user.email)
    create(:tenant_user, tenant: @tenant, user:, role:, person:, **grants)
  end

  def call(operation, account, **params)
    context = AuthorizationContext.new(user: account.user, tenant_user: account, person: account.person)
    operation.call(context:, params: params.compact)
  end
end
