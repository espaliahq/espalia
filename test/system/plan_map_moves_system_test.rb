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
      @engineer = create(:framework_role, tenant: @tenant, name: "Software Engineer")
      @e2 = create(:framework_level, tenant: @tenant, role_id: @engineer.role_id, ordinal: 2, title: "Engineer II", code: "E2")
    end

    @plan_id = call(Operations::TeamPlanning::CreatePlan, @planner, name: "Pay review 2027", base_on: (Date.current + 1).iso8601)[:plan_id]
    @q1 = call(Operations::TeamPlanning::ForkScenario, @planner, plan_id: @plan_id, relation: "then", name: "Q1 hires",
                                                                 ends_on: (Date.current + 120).iso8601)[:scenario_id]
    @position = call(Operations::TeamPlanning::SetPosition, @planner, plan_id: @plan_id, scenario_id: @q1, role_id: @engineer.role_id,
                                                                      level_id: @e2.level_id, unit_id: @payments, fte: 1, basis: "backfill")[:position_id]
    sign_in_as(@planner.user)
  end

  [ [ "desktop", DESKTOP_SIZE ], [ "phone", MOBILE_SIZE ] ].each do |label, size|
    context "on a #{label}" do
      setup { page.driver.browser.manage.window.resize_to(*size) }

      should "move a person to another unit in the scenario shown, with Move…" do
        open_move("Ada Quill")
        within("#move-person-modal") do
          assert_text "Moving Ada Quill in Q1 hires"
          assert_text "except one they already hold in the unit or position they move to, which this replaces"
          select "Growth", from: "To"
          js_fill_in "Allocation (%)", with: "50"
        end
        click_button_with_js_fallback("Save move", expect_text: "Move saved.")

        within(unit("Growth")) do
          assert_text "Ada Quill"
          assert_text "50%"
        end
        within(unit("Payments")) { assert_no_text "Ada Quill" }
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

      should "place a person in a position, with Move…" do
        open_move("Cy Loose")
        within("#move-person-modal") do
          select "Payments › Backfill: Software Engineer · Engineer II", from: "To"
          js_fill_in "Allocation (%)", with: "100"
        end
        click_button_with_js_fallback("Save move", expect_text: "Move saved.")

        within(position) { assert_text "Cy Loose · 100%" }

        click_selector_with_js_fallback("button[aria-label='Move Cy Loose']", expect_text: "Moving Cy Loose")
        within("#move-person-modal") do
          assert_equal Views::Plans::MoveDialog.position_choice(@position), find_field("To").value
        end
      end

      should "move a position to another unit in the scenario shown, with Move…" do
        visit map_plan_path(@plan_id, scenario: @q1)
        assert_text "Drag a person or a position to another unit"
        wait_for_stimulus "move-form"
        use_position_menu("Move…", expect_text: "Moving Backfill: Software Engineer in Q1 hires")
        within("#move-position-modal") do
          assert_text "The people in it move with it, and their reporting lines stay as they are."
          select "Growth", from: "To"
        end
        click_button_with_js_fallback("Save move", expect_text: "Position moved.")

        within(unit("Growth")) { assert_text "Backfill: Software Engineer" }
        within(unit("Payments")) { assert_no_text "Backfill: Software Engineer" }
        assert_no_sideways_overflow
      end

      should "open a position in a unit" do
        visit_q1
        wait_for_stimulus "position-form"
        click_selector_with_js_fallback("button[aria-label='Open a position in Growth']", expect_text: "Opening a position in Growth")
        within("#open-position-modal") do
          select "Software Engineer, E2 Engineer II", from: "Role and level"
          js_fill_in "FTE", with: "0.5"
          choose "New: planned budget"
        end
        click_button_with_js_fallback("Open position", expect_text: "Position opened.")

        within(unit("Growth")) { assert_text "New position: Software Engineer" }
        assert_no_sideways_overflow
      end

      should "edit a position's cost centre, keeping the rest" do
        visit_q1
        wait_for_stimulus "position-form"
        use_position_menu("Edit…", expect_text: "Editing Backfill: Software Engineer")
        within("#edit-position-modal") do
          assert_equal @e2.level_id, find_field("Role and level").value
          assert_checked_field "Backfill: committed budget"
          js_fill_in "Cost centre", with: "Ledger"
        end
        click_button_with_js_fallback("Save position", expect_text: "Position saved.")

        assert_equal [ "Ledger", "backfill", @payments ], scenario_position.values_at(:cost_centre, :basis, :unit_id)
        assert_no_sideways_overflow
      end

      should "keep what was typed when a save is refused" do
        visit_q1
        wait_for_stimulus "position-form"
        use_position_menu("Edit…", expect_text: "Editing Backfill: Software Engineer")
        within("#edit-position-modal") do
          js_fill_in "Cost centre", with: "Ledger"
          page.execute_script("document.getElementById('edit-position-fte').removeAttribute('max')")
          js_fill_in "FTE", with: "1.5"
        end
        click_button_with_js_fallback("Save position", expect_text: "Couldn't save the position")

        within("#edit-position-modal") do
          assert_selector "[role=alert]", text: "FTE"
          assert_field "Cost centre", with: "Ledger"
          assert_field "FTE", with: "1.5"
        end
        assert_nil scenario_position[:cost_centre]
      end

      should "close a position, naming who stays in it" do
        call(Operations::TeamPlanning::SetAssignment, @planner, plan_id: @plan_id, scenario_id: @q1, person_id: @cy.id,
                                                                placements: [ { position_id: @position, allocation: 1 } ])
        visit_q1
        wait_for_stimulus "close-position-form"
        use_position_menu("Close…", expect_text: "Closing Backfill: Software Engineer in Q1 hires")
        within("#close-position-modal") do
          assert_text "Cy Loose stay placed in it until you move them."
          assert_text "you can undo the close from Changes"
        end
        click_button_with_js_fallback("Close position", expect_text: "Position closed.")

        assert_nil scenario_position
        assert_no_sideways_overflow
      end

      should "name positions that read alike the same way on the map and in Move…" do
        twin = call(Operations::TeamPlanning::SetPosition, @planner, plan_id: @plan_id, scenario_id: @q1, role_id: @engineer.role_id,
                                                                     level_id: @e2.level_id, unit_id: @payments, fte: 1, basis: "backfill")[:position_id]
        open_move("Cy Loose")
        within("#move-person-modal") do
          select "Payments › Backfill: Software Engineer (2) · Engineer II", from: "To"
          js_fill_in "Allocation (%)", with: "100"
        end
        click_button_with_js_fallback("Save move", expect_text: "Move saved.")

        within("[data-map-position='#{twin}']") do
          assert_text "Backfill: Software Engineer (2)"
          assert_text "Cy Loose · 100%"
        end
        within(position) { assert_text "Backfill: Software Engineer (1)" }
        assert_no_sideways_overflow
      end
    end
  end

  should "open the move dialog on the unit a person is dropped on" do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    visit map_plan_path(@plan_id, scenario: @q1)
    wait_for_stimulus "map-move"
    drag("[data-map-person='#{@cy.id}']", "[data-map-unit='#{@growth}']")

    within("#move-person-modal") do
      assert_text "Moving Cy Loose in Q1 hires"
      assert_equal @growth, find_field("To").value
      assert_equal "100", find_field("Allocation (%)").value
    end
    click_button_with_js_fallback("Save move", expect_text: "Move saved.")
    within(unit("Growth")) { assert_text "Cy Loose" }
  end

  should "open the move dialog on the position a person is dropped on" do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    visit map_plan_path(@plan_id, scenario: @q1)
    wait_for_stimulus "map-move"
    drag("[data-map-person='#{@cy.id}']", "[data-map-position='#{@position}']")

    within("#move-person-modal") do
      assert_text "Moving Cy Loose in Q1 hires"
      assert_equal Views::Plans::MoveDialog.position_choice(@position), find_field("To").value
    end
    click_button_with_js_fallback("Save move", expect_text: "Move saved.")
    within(position) { assert_text "Cy Loose · 100%" }
  end

  should "let someone in a position drop on its own unit to hold a place there instead" do
    call(Operations::TeamPlanning::SetAssignment, @planner, plan_id: @plan_id, scenario_id: @q1, person_id: @cy.id,
                                                            placements: [ { position_id: @position, allocation: 1 } ])
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    visit map_plan_path(@plan_id, scenario: @q1)
    within(position) { assert_text "Cy Loose · 100%" }
    wait_for_stimulus "map-move"
    drag("[data-map-person='#{@cy.id}']", "[data-map-unit='#{@payments}']")

    within("#move-person-modal") do
      assert_text "Moving Cy Loose in Q1 hires"
      assert_equal @payments, find_field("To").value
    end
    click_button_with_js_fallback("Save move", expect_text: "Move saved.")
    assert_no_selector "[data-map-occupant='#{@cy.id}']"
    within(unit("Payments")) { assert_text "Cy Loose" }
  end

  should "open no dialog when someone is dropped on the position they hold" do
    call(Operations::TeamPlanning::SetAssignment, @planner, plan_id: @plan_id, scenario_id: @q1, person_id: @cy.id,
                                                            placements: [ { position_id: @position, allocation: 1 } ])
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    visit map_plan_path(@plan_id, scenario: @q1)
    within(position) { assert_text "Cy Loose · 100%" }
    wait_for_stimulus "map-move"
    drag("[data-map-person='#{@cy.id}']", "[data-map-position='#{@position}']")

    assert_no_selector "#move-person-modal", visible: true
  end

  should "open the position dialog on the unit a position is dropped on" do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    visit map_plan_path(@plan_id, scenario: @q1)
    wait_for_stimulus "map-move"
    drag("[data-map-position='#{@position}']", "[data-map-unit='#{@growth}']")

    within("#move-position-modal") do
      assert_text "Moving Backfill: Software Engineer in Q1 hires"
      assert_equal @growth, find_field("To").value
    end
    click_button_with_js_fallback("Save move", expect_text: "Position moved.")
    within(unit("Growth")) { assert_text "Backfill: Software Engineer" }
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
    assert_no_button "Open a position"
    assert_no_selector "button[aria-label^='Actions for']"
    assert_no_selector "[draggable]"
  end

  private

  # Selenium can't drive HTML5 drag and drop, so the events are dispatched.
  def drag(from, to)
    page.execute_script(<<~JS, from, to)
      const row = document.querySelector(arguments[0])
      const target = document.querySelector(arguments[1])
      const dataTransfer = new DataTransfer()
      const fire = (element, type) => element.dispatchEvent(new DragEvent(type, { bubbles: true, cancelable: true, dataTransfer }))
      fire(row, "dragstart")
      fire(target, "dragover")
      fire(target, "drop")
      fire(row, "dragend")
    JS
  end

  def position = find("[data-map-position='#{@position}']")

  def visit_q1
    visit map_plan_path(@plan_id, scenario: @q1)
    assert_text "Drag a person or a position to another unit"
  end

  MENU_ITEMS = { "Edit…" => "edit-position-modal", "Move…" => "move-position-modal", "Close…" => "close-position-modal" }.freeze

  # The menu opens fixed at its trigger, so the row has to be on screen, as it is
  # under a real tap.
  def use_position_menu(item, expect_text:)
    row = "[data-map-position='#{@position}']"
    page.execute_script("document.querySelector(arguments[0]).scrollIntoView({ block: 'center' })", row)
    open_dropdown(scope: row)
    click_selector_with_js_fallback("#{row} [role=menuitem][data-modal-target-id='#{MENU_ITEMS.fetch(item)}']", expect_text:)
  end

  def scenario_position
    ActsAsTenant.with_tenant(@tenant) do
      call(Operations::TeamPlanning::ScenarioMap, @planner, plan_id: @plan_id, scenario_id: @q1)[:positions]
        .find { it[:position_id] == @position }
    end
  end

  def open_move(name)
    visit map_plan_path(@plan_id, scenario: @q1)
    assert_text "Drag a person or a position to another unit"
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
