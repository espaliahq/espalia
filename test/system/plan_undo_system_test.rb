# frozen_string_literal: true

require "application_system_test_case"

class PlanUndoSystemTest < ApplicationSystemTestCase
  ESPALIA = { provider: "espalia" }.freeze
  PAY = { amount: "93871", currency: "EUR", period: "year", basis: "full_time" }.freeze
  UNDO = "[data-undo-control='undo'] button"
  REDO = "[data-undo-control='redo'] button"

  setup do
    @tenant = create(:tenant, :with_hibob_config)
    people = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    since = (Date.current - 30).iso8601
    teams = SecureRandom.uuid_v7
    @payments = SecureRandom.uuid_v7

    ActsAsTenant.with_tenant(@tenant) do
      @planner = account(team_planner: true, name: "Erin Editor")
      @editor = account(name: "Eli Editor")
      @viewer = account(name: "Vic Viewer")
      engineer = create(:framework_role, code: "E", name: "Software Engineer")
      e5 = create(:framework_level, role_id: engineer.role_id, ordinal: 5, title: "Senior SWE")
      structure.define_taxonomy([ { level_id: teams, name: "Team" } ], effective_on: since)
      structure.create_unit(@payments, "Payments", level_id: teams, effective_on: since)
      @ada, @bo = %w[Ada Bo].map { create(:person, tenant: @tenant, name: "#{it} Quill") }
      [ @ada, @bo ].each do |person|
        people.record_person(person.id, **ESPALIA, effective_on: since, employment_status: "employed", title: "Software Engineer", level: "5", fte: 1.0)
        people.set_membership(person.id, @payments, **ESPALIA, effective_on: since, allocation: 1.0)
      end
      PayBand.create!(level: e5, currency: "EUR", period: "year", minimum: 61_000, midpoint: 100_000, maximum: 177_419)
      ReferenceCurrency.create!(currency: "EUR")
      @level_id = e5.level_id
      @role_id = engineer.role_id
    end

    @plan_id = call(Operations::TeamPlanning::CreatePlan, @planner, name: "Next year", base_on: (Date.current + 1).iso8601)[:plan_id]
    call(Operations::TeamPlanning::AddPlanMember, @planner, plan_id: @plan_id, person_id: @editor.person.id, role: "editor")
    call(Operations::TeamPlanning::AddPlanMember, @planner, plan_id: @plan_id, person_id: @viewer.person.id, role: "viewer")
    @year = call(Operations::TeamPlanning::ForkScenario, @planner, plan_id: @plan_id, relation: "then", name: "Year one",
                                                                   ends_on: (Date.current + 365).iso8601)[:scenario_id]
    @position_id = call(Operations::TeamPlanning::SetPosition, @planner, plan_id: @plan_id, scenario_id: @year, role_id: @role_id,
                                                                         level_id: @level_id, unit_id: @payments, fte: 0.5, basis: "new")[:position_id]
  end

  [ [ "desktop", DESKTOP_SIZE ], [ "phone", MOBILE_SIZE ] ].each do |label, size|
    context "on a #{label}" do
      setup { page.driver.browser.manage.window.resize_to(*size) }

      should "undo the latest change, after which the cost strip, the map and the Changes tab agree, then redo it" do
        sign_in_as(@planner.user)
        visit map_plan_path(@plan_id, scenario: @year)
        assert_plan_holds_position(true)
        assert_selector UNDO, visible: true
        assert_equal "Undo: Position", find(UNDO)["aria-label"]
        assert_no_selector REDO
        assert_no_sideways_overflow

        click_selector_with_js_fallback(UNDO, expect_text: "Change undone.")
        assert_plan_holds_position(false)
        assert_equal "Redo: Position", find(REDO)["aria-label"]

        click_selector_with_js_fallback(REDO, expect_text: "Change redone.")
        assert_plan_holds_position(true)
      end

      should "name the person and facet an undo acts on, and never the amount of a pay change" do
        call(Operations::TeamPlanning::GrantSeePay, @planner, plan_id: @plan_id, person_id: @editor.person.id)
        call(Operations::TeamPlanning::SetPlannedLevel, @editor, plan_id: @plan_id, scenario_id: @year, person_id: @bo.id, level: "6")
        call(Operations::TeamPlanning::SetActualPay, @editor, plan_id: @plan_id, scenario_id: @year, person_id: @ada.id, **PAY)

        sign_in_as(@editor.user)
        visit changes_plan_path(@plan_id, scenario: @year)
        assert_equal "Undo: Ada Quill · Pay", find(UNDO)["aria-label"]
        assert_no_text PAY[:amount]

        call(Operations::TeamPlanning::WithdrawSeePay, @planner, plan_id: @plan_id, person_id: @editor.person.id)
        visit changes_plan_path(@plan_id, scenario: @year)
        assert_equal "Undo: Bo Quill · Level", find(UNDO)["aria-label"]
        assert_selector "[data-clear-change='level']", visible: true
        assert_no_selector "[data-clear-change='data:pay']", visible: :all
        assert_no_selector "[data-undo-control]", text: "Pay", visible: :all
        assert_not_includes page.html, "Ada Quill · Pay"
        assert_not_includes page.html, PAY[:amount]
      end

      should "clear a change after saying what the scenario follows again, and offer Undo to bring it back" do
        sign_in_as(@planner.user)
        visit changes_plan_path(@plan_id, scenario: @year)
        assert_selector "[data-planned-change]", count: 1

        click_selector_with_js_fallback("[data-clear-change='position']", expect_selector: "[id^='clear-'][role='dialog']:not(.hidden)")
        within("[id^='clear-'][role='dialog']") do
          assert_text "Year one will follow Today again here. The change stays in the history, and Undo brings it back."
        end
        click_button_with_js_fallback("Clear change", expect_text: "Change cleared.")
        assert_text "This scenario plans nothing yet."
        assert_equal "Undo: Position", find(UNDO)["aria-label"]

        visit map_plan_path(@plan_id, scenario: @year)
        assert_plan_holds_position(false)
      end

      should "change nothing when someone else changed the plan after the page loaded" do
        sign_in_as(@planner.user)
        visit map_plan_path(@plan_id, scenario: @year)
        assert_selector UNDO
        call(Operations::TeamPlanning::SetPosition, @editor, plan_id: @plan_id, scenario_id: @year, position_id: @position_id, role_id: @role_id,
                                                             level_id: @level_id, unit_id: @payments, fte: 1.0, basis: "new")

        click_selector_with_js_fallback(UNDO, expect_text: "The page was out of date, so nothing changed.")
        assert_plan_holds_position(true, total: "EUR 300k")
      end

      should "offer a viewer no undo, redo or clear" do
        sign_in_as(@viewer.user)
        visit changes_plan_path(@plan_id, scenario: @year)
        assert_selector "[data-planned-change]", count: 1
        assert_no_undo_controls
        visit map_plan_path(@plan_id, scenario: @year)
        assert_selector "[data-map-position]"
        assert_no_undo_controls
      end

      should "offer nothing in Today, nor on an archived plan" do
        call(Operations::TeamPlanning::SetPlannedLevel, @planner, plan_id: @plan_id, scenario_id: @plan_id, person_id: @bo.id, level: "6")
        sign_in_as(@planner.user)
        visit changes_plan_path(@plan_id)
        assert_selector "[data-planned-change]", text: "Bo Quill"
        assert_no_undo_controls

        call(Operations::TeamPlanning::ArchivePlan, @planner, plan_id: @plan_id)
        visit changes_plan_path(@plan_id, scenario: @year)
        assert_text "Archived on"
        assert_no_undo_controls
      end
    end
  end

  should "keep the tabs on one line beside Undo and Redo at 1024 and 1280 pixels with the panel open or closed, and add no row on a phone" do
    call(Operations::TeamPlanning::SetPlannedLevel, @planner, plan_id: @plan_id, scenario_id: @year, person_id: @bo.id, level: "6")
    call(Operations::TeamPlanning::UndoChange, @planner, plan_id: @plan_id, scenario_id: @year)
    sign_in_as(@planner.user)

    paths = %w[open closed].flat_map do |panel|
      [ map_plan_path(@plan_id, scenario: @year, panel:), changes_plan_path(@plan_id, scenario: @year, panel:) ]
    end
    [ MOBILE_SIZE, [ 1024, 900 ], [ 1280, 900 ] ].product(paths).each do |(width, height), path|
      page.driver.browser.manage.window.resize_to(width, height)
      visit path
      assert_selector "#{REDO}[aria-label='Redo: Bo Quill · Level']"
      assert_selector "#{UNDO}[aria-label='Undo: Position']"
      if width == MOBILE_SIZE.first
        with_controls = tab_rows
        execute_script("document.querySelectorAll('[data-undo-control]').forEach(it => it.remove())")
        assert_equal tab_rows, with_controls, "Undo and Redo wrap the tab strip on #{path} on a phone"
      else
        assert_equal 1, tab_rows, "the tab strip wraps on #{path} at #{width}"
        assert_equal 0, tabs_scrolled_away, "the tab strip hides a tab behind its scroll on #{path} at #{width}"
      end
      assert_no_sideways_overflow
    end
  end

  private

  def tabs_scrolled_away = evaluate_script(%(document.querySelector('nav[aria-label="Plan views"] > div').scrollWidth - document.querySelector('nav[aria-label="Plan views"] > div').clientWidth))

  def tab_rows = evaluate_script(%(new Set([...document.querySelectorAll('nav[aria-label="Plan views"] a')].map(a => a.getBoundingClientRect().top)).size))

  def assert_plan_holds_position(held, total: held ? "EUR 250k" : "EUR 200k")
    within("[data-cost-strip]") { assert_selector "[data-cost-total]", text: total }
    held ? assert_selector("[data-map-position]") : assert_no_selector("[data-map-position]")
    visit changes_plan_path(@plan_id, scenario: @year)
    within("[data-changes-section='planned']") do
      held ? assert_selector("[data-planned-change]", text: "Position") : assert_text("This scenario plans nothing yet.")
    end
    visit map_plan_path(@plan_id, scenario: @year)
    assert_selector "[data-cost-strip]"
  end

  def assert_no_undo_controls
    assert_no_selector "[data-undo-control]", visible: :all
    assert_no_selector "[data-clear-change]", visible: :all
  end

  def account(role: :member, name: "Someone", **grants)
    user = create(:user, password: TEST_PASSWORD)
    person = create(:person, tenant: @tenant, name:, email: user.email)
    create(:tenant_user, tenant: @tenant, user:, role:, person:, **grants)
  end

  def call(operation, account, **params)
    ActsAsTenant.with_tenant(@tenant) do
      context = AuthorizationContext.new(user: account.user, tenant_user: account, person: account.person)
      operation.call(context:, params:)
    end
  end
end
