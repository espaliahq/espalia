# frozen_string_literal: true

require "application_system_test_case"

class PlanMapMovesSystemTest < ApplicationSystemTestCase
  ESPALIA = { provider: "espalia" }.freeze

  setup do
    @tenant = create(:tenant)
    handler = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    since = (Date.current - 30).iso8601
    team = SecureRandom.uuid_v7
    @payments = SecureRandom.uuid_v7
    @growth = SecureRandom.uuid_v7

    ActsAsTenant.with_tenant(@tenant) do
      @planner = account(team_planner: true, name: "Erin Editor")
      @ada = create(:person, tenant: @tenant, name: "Ada Quill")
      @cy = create(:person, tenant: @tenant, name: "Cy Loose")
      structure.define_taxonomy([ { level_id: team, name: "Team" } ], effective_on: since)
      structure.create_unit(@payments, "Payments", level_id: team, effective_on: since)
      structure.create_unit(@growth, "Growth", level_id: team, effective_on: since)
      handler.record_person(@ada.id, **ESPALIA, effective_on: since, employment_status: "employed")
      handler.set_membership(@ada.id, @payments, **ESPALIA, effective_on: since, allocation: 1.0, role: "ENG")
      handler.record_person(@cy.id, **ESPALIA, effective_on: since, employment_status: "employed")
    end

    @plan_id = call(Operations::TeamPlanning::CreatePlan, @planner, name: "Pay review 2027", base_on: (Date.current + 1).iso8601)[:plan_id]
    @q1 = call(Operations::TeamPlanning::ForkScenario, @planner, plan_id: @plan_id, relation: "then", name: "Q1 hires",
                                                                 ends_on: (Date.current + 120).iso8601)[:scenario_id]
    sign_in_as(@planner.user)
  end

  [ [ "desktop", DESKTOP_SIZE ], [ "phone", MOBILE_SIZE ] ].each do |label, size|
    context "on a #{label}" do
      setup { page.driver.browser.manage.window.resize_to(*size) }

      should "move a person to another unit in the scenario shown, with Move…" do
        open_move("Ada Quill")
        within("#move-person-modal") do
          assert_text "Moving Ada Quill in Q1 hires"
          assert_text "except one they already hold in the unit they move to, which this replaces"
          select "Growth", from: "To"
          js_fill_in "Allocation (%)", with: "50"
        end
        click_button_with_js_fallback("Save move", expect_text: "Move saved.")

        within(unit("Growth")) do
          assert_text "Ada Quill"
          assert_text "50%"
        end
        within(unit("Payments")) { assert_text "Nobody yet." }
        assert_no_sideways_overflow
      end

      should "take someone out of a unit, with no allocation to set" do
        open_move("Ada Quill")
        within("#move-person-modal") do
          select "Unassigned", from: "To"
          assert_no_field "Allocation (%)"
        end
        click_button_with_js_fallback("Save move", expect_text: "Move saved.")

        within(unit("Unassigned")) { assert_text "Ada Quill" }
      end
    end
  end

  should "open the move dialog on the unit a person is dropped on" do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    visit map_plan_path(@plan_id, scenario: @q1)
    wait_for_stimulus "map-move"
    page.execute_script(<<~JS, @cy.id, @growth)
      const row = document.querySelector(`[data-map-person="${arguments[0]}"]`)
      const target = document.querySelector(`[data-map-unit="${arguments[1]}"]`)
      const dataTransfer = new DataTransfer()
      const fire = (element, type) => element.dispatchEvent(new DragEvent(type, { bubbles: true, cancelable: true, dataTransfer }))
      fire(row, "dragstart")
      fire(target, "dragover")
      fire(target, "drop")
      fire(row, "dragend")
    JS

    within("#move-person-modal") do
      assert_text "Moving Cy Loose in Q1 hires"
      assert_equal @growth, find_field("To").value
      assert_equal "100", find_field("Allocation (%)").value
    end
    click_button_with_js_fallback("Save move", expect_text: "Move saved.")
    within(unit("Growth")) { assert_text "Cy Loose" }
  end

  should "start the allocation of a place the HRIS gave none at the share it counts for" do
    ActsAsTenant.with_tenant(@tenant) do
      bea = create(:person, tenant: @tenant, name: "Bea Split")
      handler = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
      since = (Date.current - 30).iso8601
      handler.record_person(bea.id, **ESPALIA, effective_on: since, employment_status: "employed")
      handler.set_membership(bea.id, @payments, **ESPALIA, effective_on: since, allocation: 0.6)
      handler.set_membership(bea.id, @growth, **ESPALIA, effective_on: since)
    end

    visit map_plan_path(@plan_id, scenario: @q1)
    wait_for_stimulus "move-form"
    within(unit("Growth")) { find("button[aria-label='Move Bea Split']").execute_script("this.click()") }
    within("#move-person-modal") do
      assert_text "Moving Bea Split in Q1 hires"
      assert_field "Allocation (%)", with: "40"
    end
  end

  should "offer no handles on Today" do
    visit map_plan_path(@plan_id)
    assert_text "Pick or fork a scenario to move people."
    assert_no_button "Move…"
    assert_no_selector "[draggable]"
  end

  private

  def open_move(name)
    visit map_plan_path(@plan_id, scenario: @q1)
    assert_text "Drag a person to another unit"
    wait_for_stimulus "move-form"
    click_selector_with_js_fallback("button[aria-label='Move #{name}']", expect_text: "Moving #{name}")
  end

  def unit(name) = find("[data-map-unit]", text: name, match: :first)

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
