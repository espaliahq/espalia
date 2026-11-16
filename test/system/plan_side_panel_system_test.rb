# frozen_string_literal: true

require "application_system_test_case"

class PlanSidePanelSystemTest < ApplicationSystemTestCase
  ESPALIA = { provider: "espalia" }.freeze
  PANEL = "aside#plan-side-panel"
  TOGGLE = "button[aria-controls='plan-side-panel']"

  setup do
    @tenant = create(:tenant)
    handler = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    since = (Date.current - 30).iso8601
    team = SecureRandom.uuid_v7

    ActsAsTenant.with_tenant(@tenant) do
      @planner = account(name: "Erin Editor")
      ada = create(:person, tenant: @tenant, name: "Ada Quill")
      structure.define_taxonomy([ { level_id: team, name: "Team" } ], effective_on: since)
      %w[Payments Growth Search Ledger Billing].each do |name|
        structure.create_unit(unit = SecureRandom.uuid_v7, name, level_id: team, effective_on: since)
        @payments ||= unit
      end
      handler.record_person(ada.id, **ESPALIA, effective_on: since, employment_status: "employed")
      handler.set_membership(ada.id, @payments, **ESPALIA, effective_on: since, allocation: 1.0, role: "ENG")
    end

    @plan_id = create_plan("Pay review 2027")
    call(Operations::TeamPlanning::ForkScenario, @planner, plan_id: @plan_id, relation: "then", name: "Q1 hires",
                                                           ends_on: (Date.current + 120).iso8601)
  end

  [ [ "desktop", DESKTOP_SIZE ], [ "phone", MOBILE_SIZE ] ].each do |label, size|
    context "on a #{label}" do
      setup do
        page.driver.browser.manage.window.resize_to(*size)
        sign_in_as(@planner.user)
      end

      should "start closed on the Map once the plan has a scenario, and remember opening it" do
        visit map_plan_path(@plan_id)
        assert_selector "[data-map-unit]", text: "Payments"
        assert_no_selector PANEL, visible: true
        assert_selector "#{TOGGLE}[aria-expanded='false']"
        closed_width = map_width

        toggle_side_panel
        assert_selector PANEL, visible: true, text: "Members"
        assert_selector "#{TOGGLE}[aria-expanded='true']"
        assert_includes current_url, "panel=open"
        assert_operator map_width, :<, closed_width if label == "desktop"
        if label == "phone"
          assert_panel_in_view
          tap_the_map
          assert_selector PANEL, visible: true, text: "Members"
        end

        visit map_plan_path(@plan_id)
        assert_selector "[data-map-unit]", text: "Payments"
        assert_selector PANEL, visible: true, text: "Members"
        assert_selector "#{TOGGLE}[aria-expanded='true']"
      end

      should "start open beside the scenarios, and stay closed once closed from its own button" do
        visit plan_path(@plan_id)
        assert_selector PANEL, visible: true, text: "Members"

        wait_for_stimulus "activity-pane"
        page.execute_script("document.querySelector(arguments[0]).click()", "#{PANEL} button[aria-label='Close about this plan']")
        assert_no_selector PANEL, visible: true
        assert_selector "#{TOGGLE}[aria-expanded='false']"
        assert_includes current_url, "panel=closed"

        visit plan_path(@plan_id)
        assert_selector "#{TOGGLE}[aria-expanded='false']"
        assert_no_selector PANEL, visible: true
        assert_no_sideways_overflow

        page.execute_script("const t = document.querySelector(arguments[0]); t.after(t.cloneNode(true))", TOGGLE)
        toggle_side_panel
        assert_selector PANEL, visible: true, text: "Members"
        assert_selector "#{TOGGLE}[aria-expanded='true']", count: 2
      end

      should "start open on the Map of a plan with no scenarios yet" do
        visit map_plan_path(create_plan("Hiring 2027"))
        assert_selector "[data-map-unit]", text: "Payments"
        assert_selector PANEL, visible: true, text: "Members"
        assert_selector "#{TOGGLE}[aria-expanded='true']"
      end
    end
  end

  private

  def toggle_side_panel
    wait_for_stimulus "activity-pane"
    page.execute_script("document.querySelector(arguments[0]).click()", TOGGLE)
  end

  def assert_panel_in_view
    page.document.synchronize do
      in_view = evaluate_script("(r => r.top >= 0 && r.top < innerHeight)(document.querySelector('#{PANEL}').getBoundingClientRect())")
      raise Capybara::ExpectationNotMet, "the panel is out of view" unless in_view
    end
  end

  # The stacked panel ignores a tap outside it, which on a phone is a tap on the page.
  def tap_the_map
    page.execute_script(<<~JS)
      document.querySelector("[data-map-unit]").dispatchEvent(
        new MouseEvent("click", { bubbles: true, cancelable: true, view: window })
      )
    JS
  end

  def map_width
    evaluate_script("document.querySelector('[data-map-unit]').parentElement.getBoundingClientRect().width")
  end

  def create_plan(name)
    call(Operations::TeamPlanning::CreatePlan, @planner, name:, base_on: (Date.current + 1).iso8601)[:plan_id]
  end

  def account(name:)
    user = create(:user, password: TEST_PASSWORD)
    person = create(:person, tenant: @tenant, name:, email: user.email)
    create(:tenant_user, tenant: @tenant, user:, person:, team_planner: true)
  end

  def call(operation, account, **params)
    ActsAsTenant.with_tenant(@tenant) do
      context = AuthorizationContext.new(user: account.user, tenant_user: account, person: account.person)
      operation.call(context:, params:)
    end
  end
end
