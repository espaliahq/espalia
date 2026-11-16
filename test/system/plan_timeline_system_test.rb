# frozen_string_literal: true

require "application_system_test_case"

class PlanTimelineSystemTest < ApplicationSystemTestCase
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
      @viewer = account(name: "Vic Viewer")
      @outsider = account(name: "Olly Outsider")
      @ada = create(:person, tenant: @tenant, name: "Ada Quill")
      @bo = create(:person, tenant: @tenant, name: "Bo Reyes")
      @engineer = create(:framework_role, tenant: @tenant, name: "Software Engineer")
      @level_id = create(:framework_level, tenant: @tenant, role_id: @engineer.role_id, ordinal: 2, title: "Engineer II").level_id

      structure.define_taxonomy([ { level_id: team, name: "Team" } ], effective_on: since)
      structure.create_unit(@payments, "Payments", level_id: team, effective_on: since)
      structure.create_unit(@growth, "Growth", level_id: team, effective_on: since)
      handler.record_person(@ada.id, **ESPALIA, effective_on: since, employment_status: "employed")
      handler.set_membership(@ada.id, @payments, **ESPALIA, effective_on: since, allocation: 1.0, role: "ENG")
      handler.record_person(@bo.id, **ESPALIA, effective_on: since, employment_status: "employed")
      handler.set_membership(@bo.id, @payments, **ESPALIA, effective_on: since, allocation: 1.0, role: "PM")
    end

    # The baseline reads the Org Graph as known the day before the base date, so a plan based tomorrow sees today's facts.
    @plan_id = call(Operations::TeamPlanning::CreatePlan, @planner, name: "Pay review 2027", base_on: (Date.current + 1).iso8601)[:plan_id]
    call(Operations::TeamPlanning::AddPlanMember, @planner, plan_id: @plan_id, person_id: @viewer.person.id, role: "viewer")
    @q1 = fork(relation: "then", name: "Q1 hires", ends_on: (Date.current + 120).iso8601)
    fork(parent_id: @q1, relation: "then", name: "Q2 settle", ends_on: (Date.current + 240).iso8601)
    call(Operations::TeamPlanning::SetAssignment, @planner, plan_id: @plan_id, scenario_id: @q1, person_id: @bo.id,
                                                            placements: [ { unit_id: @growth, allocation: 1, role: "PM" } ])
    backfill = call(Operations::TeamPlanning::SetPosition, @planner, plan_id: @plan_id, scenario_id: @q1, role_id: @engineer.role_id,
                                                                     level_id: @level_id, unit_id: @payments, fte: 1, basis: "backfill")[:position_id]
    call(Operations::TeamPlanning::SetDeparture, @planner, plan_id: @plan_id, scenario_id: @q1, person_id: @ada.id, position_id: backfill)
    # An alternative inherits Q1's changes; this one keeps Ada.
    lean = fork(parent_id: @q1, relation: "instead", name: "Lean Q1", ends_on: (Date.current + 120).iso8601)
    call(Operations::TeamPlanning::WithdrawDeparture, @planner, plan_id: @plan_id, scenario_id: lean, person_id: @ada.id)
  end

  context "on a desktop" do
    setup { page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE) }

    should "lay the first path out a column per step, with each block's lanes, moves and backfills" do
      sign_in_as(@viewer.user)
      visit plan_path(@plan_id)
      click_link_with_js_fallback("Timeline", expect_text: "Showing the path to Q2 settle.")

      within("[data-timeline-grid]") do
        assert_selector "[data-timeline-step]", count: 3
        assert_selector "[data-timeline-step='0']", text: "Today"
        assert_selector "[data-timeline-step='1']", text: "Q1 hires"
        assert_selector "[data-timeline-step='2']", text: "Q2 settle"
        assert_selector "h3", text: "Payments"
        assert_selector "h3", text: "Growth"
        assert_text "ENG"
        assert_selector "[data-timeline-lane]", text: /Ada\s+Quill\s+leaves\s+in\s+Q1\s+hires/
        assert_selector "[data-timeline-lane]", text: "Replaces Ada Quill. Backfill, Software Engineer, Engineer II"
        assert_selector "[data-timeline-lane]", text: /Bo\s+Reyes\s+to\s+Growth/
        assert_selector "[data-timeline-lane]", text: /from\s+Payments\s+Bo\s+Reyes/
      end
      assert_leaver_clear_of_backfill
      assert_text "One other path runs through this plan"
      assert_no_sideways_overflow
    end

    should "follow an alternative to redraw the path" do
      sign_in_as(@viewer.user)
      visit timeline_plan_path(@plan_id)
      assert_text "Showing the path to Q2 settle."

      within("[data-timeline-step='1']") { assert_text "or instead Lean Q1" }
      click_link_with_js_fallback("Lean Q1", expect_text: "Showing the path to Lean Q1.")

      within("[data-timeline-grid]") do
        assert_selector "[data-timeline-step]", count: 2
        assert_selector "[data-timeline-lane]", text: "Ada Quill"
        assert_no_text "leaves in"
        assert_no_text "Replaces Ada Quill"
      end
      assert_text "or instead Q1 hires"
    end
  end

  context "on a phone" do
    setup { page.driver.browser.manage.window.resize_to(*MOBILE_SIZE) }

    should "show one step at a time, each lane saying where it came from and goes" do
      sign_in_as(@viewer.user)
      visit timeline_plan_path(@plan_id)
      assert_text "Step 1 of 3"
      assert_no_selector "[data-timeline-grid]", visible: true

      within("[data-timeline-phone]") do
        assert_selector "a[aria-current='step']", text: "Today"
        assert_selector "[data-timeline-lane]", text: /Bo\s+Reyes\s+to\s+Growth/
        assert_selector "[data-timeline-lane]", text: "Ada Quill"
      end
      assert_no_sideways_overflow

      click_link_with_js_fallback("Q1 hires", expect_text: "Step 2 of 3")
      within("[data-timeline-phone]") do
        assert_selector "a[aria-current='step']", text: "Q1 hires"
        assert_text "or instead Lean Q1"
        assert_selector "[data-timeline-lane]", text: /from\s+Payments\s+Bo\s+Reyes/
        assert_selector "[data-timeline-lane]", text: /Ada\s+Quill\s+leaves\s+in\s+Q1\s+hires/
        assert_selector "[data-timeline-lane]", text: "Replaces Ada Quill"
      end
      assert_no_sideways_overflow
    end

    should "show an outsider no timeline" do
      sign_in_as(@outsider.user)
      visit timeline_plan_path(@plan_id)
      # The test environment shows Rails' error page, so the 404 reads as the exception that makes one.
      assert_text "ActiveRecord::RecordNotFound"
      [ "Pay review 2027", "Payments", "Ada Quill" ].each { assert_no_text it }
    end
  end

  context "as a planner" do
    setup { sign_in_as(@planner.user) }

    should "move a person in a later step by dragging their bar onto another unit, and stay on the timeline" do
      page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
      visit timeline_plan_path(@plan_id)
      assert_text "Showing the path to Q2 settle."
      wait_for_stimulus "map-move"
      wait_for_stimulus "move-form"
      within("[data-timeline-grid]") { assert_no_selector "[draggable][data-map-from-step='0']" }

      drag("[draggable][data-map-person='#{@bo.id}']", "[data-map-unit='#{@payments}'][data-map-step='2']")
      within("#move-person-modal-2") do
        assert_text "Moving Bo Reyes in Q2 settle"
        assert_select "To", selected: "Payments"
      end
      click_button_with_js_fallback("Save move", expect_text: "Move saved.")

      assert_text "Showing the path to Q2 settle."
      assert_selector "[data-timeline-lane]", text: /Bo\s+Reyes\s+to\s+Payments/
      assert_no_sideways_overflow
    end

    should "refuse a drop in a step the bar doesn't cover" do
      page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
      visit timeline_plan_path(@plan_id)
      wait_for_stimulus "map-move"
      assert_no_selector "[data-map-unit='#{@payments}'][data-map-step='0']"

      assert drag("[draggable][data-map-person='#{@ada.id}']", "[data-map-unit='#{@growth}'][data-map-step='1']"), "a step the bar covers takes the drop"
      assert_selector "#move-person-modal-1", text: "Moving Ada Quill in Q1 hires", visible: true
      press_escape
      assert_not drag("[draggable][data-map-person='#{@ada.id}']", "[data-map-unit='#{@growth}'][data-map-step='2']"), "Ada leaves in Q1 hires, so Q2 settle has no bar of hers to move"
    end

    should "take a drop on Unassigned while nobody is unassigned" do
      page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
      visit timeline_plan_path(@plan_id)
      wait_for_stimulus "map-move"
      wait_for_stimulus "move-form"

      drag("[draggable][data-map-person='#{@bo.id}']", "[data-map-unit='#{Views::Plans::MoveDialog::UNASSIGNED}'][data-map-step='2']")
      within("#move-person-modal-2") do
        assert_text "Moving Bo Reyes in Q2 settle"
        assert_select "To", selected: "Unassigned"
      end
    end

    should "move a person on a phone from the bar's Move…, in the step shown" do
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      visit timeline_plan_path(@plan_id, step: 1)
      assert_text "Step 2 of 3"
      assert_no_selector "[data-timeline-shift-edge]"
      wait_for_stimulus "move-form"
      click_selector_with_js_fallback("[data-timeline-phone] button[aria-label='Move Bo Reyes in Q1 hires']", expect_text: "Moving Bo Reyes in Q1 hires")
      within("#move-person-modal-1") { select "Unassigned", from: "To" }
      click_button_with_js_fallback("Save move", expect_text: "Move saved.")

      assert_text "Step 2 of 3"
      within("[data-timeline-phone]") { assert_selector "[data-timeline-lane]", text: "Bo Reyes" }
      assert_no_sideways_overflow
    end
    should "move a departure a step later from the bar's When…, and stay on the timeline" do
      page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
      visit timeline_plan_path(@plan_id)
      assert_text "Showing the path to Q2 settle."
      within("[data-timeline-grid]") { assert_selector "[data-timeline-lane]", text: "leaves in Q1 hires" }

      within("[data-timeline-grid]") do
        click_selector_with_js_fallback("button[aria-label='Change when, for Ada Quill']", expect_text: "Leave in Q2 settle instead")
      end
      click_link_with_js_fallback("Leave in Q2 settle instead", expect_text: "Moved to Q2 settle.")

      assert_text "Showing the path to Q2 settle."
      within("[data-timeline-grid]") do
        assert_selector "[data-timeline-lane]", text: "leaves in Q2 settle"
        assert_no_text "leaves in Q1 hires"
      end
      assert_no_sideways_overflow
    end

    context "dragging a bar's edge" do
      setup do
        page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
        visit timeline_plan_path(@plan_id)
        assert_text "Showing the path to Q2 settle."
        wait_for_stimulus "timeline-shift"
      end

      should "move a departure a step later by dropping its end on the lit column" do
        assert_no_selector "[data-timeline-shift-hint='2']", visible: true
        assert page.evaluate_script("document.querySelector(\"[data-timeline-shift-hint='2']\").offsetHeight").positive?,
               "the unseen hint keeps its line, so the header row can't grow under the pointer mid-drag"
        hold(leaver_end_grip, over: "[data-timeline-step='2']")
        assert_selector "[data-timeline-shift-hint='2']", text: "Move here", visible: true
        assert_no_selector "[data-timeline-shift-hint='0']", visible: true
        assert page.evaluate_script(<<~JS), "the lit column paints over its own hint"
          (() => {
            // The overlay ignores the pointer, so it takes hits only while this reads what paints on top.
            const column = document.querySelector("[data-timeline-shift-column='2']")
            column.style.pointerEvents = "auto"
            const hint = document.querySelector("[data-timeline-shift-hint='2']").getBoundingClientRect()
            const top = document.elementFromPoint(hint.left + hint.width / 2, hint.top + hint.height / 2)
            column.style.pointerEvents = ""
            return top.dataset.timelineShiftHint === "2"
          })()
        JS
        release

        assert_text "Moved to Q2 settle."
        within("[data-timeline-grid]") do
          assert_selector "[data-timeline-lane]", text: "leaves in Q2 settle"
          assert_no_text "leaves in Q1 hires"
        end
      end

      should "save nothing for a drop on a column that isn't lit" do
        hold(leaver_end_grip, over: "[data-timeline-step='0']")
        assert_selector "[data-timeline-shift-hint='2']", text: "Move here", visible: true
        release

        assert_no_selector "[data-timeline-shift-hint='2']", visible: true
        assert_no_text "Moved to"
        within("[data-timeline-grid]") { assert_selector "[data-timeline-lane]", text: "leaves in Q1 hires" }
      end

      should "save nothing when Escape lets go of the edge" do
        hold(leaver_end_grip, over: "[data-timeline-step='2']")
        assert_selector "[data-timeline-shift-hint='2']", visible: true
        press_escape
        assert_no_selector "[data-timeline-shift-hint='2']", visible: true
        release

        assert_no_text "Moved to"
        within("[data-timeline-grid]") { assert_selector "[data-timeline-lane]", text: "leaves in Q1 hires" }
      end

      should "post one move while the first drop's request is still on its way" do
        page.execute_script(<<~JS)
          window.shiftPosts = 0
          document.addEventListener("turbo:before-fetch-request", (event) => {
            if (event.detail.fetchOptions.method.toUpperCase() !== "POST") return
            window.shiftPosts += 1
            event.preventDefault()
          })
        JS
        2.times do
          hold(leaver_end_grip, over: "[data-timeline-step='2']")
          release
        end

        assert_equal 1, page.evaluate_script("window.shiftPosts")
      end

      should "let go cleanly when the held grip leaves the page" do
        hold(leaver_end_grip, over: "[data-timeline-step='2']")
        assert_selector "[data-timeline-shift-hint='2']", visible: true
        page.execute_script("document.querySelectorAll('[data-shifting] > [data-timeline-shift-edge]').forEach(grip => grip.remove())")
        release
        press_escape

        assert_no_selector "[data-timeline-shift-hint='2']", visible: true
        assert_no_text "Moved to"
      end
    end

    should "move a change of place a step later on a phone, from the step that makes it" do
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      visit timeline_plan_path(@plan_id, step: 1)
      assert_text "Step 2 of 3"

      within("[data-timeline-phone]") do
        click_selector_with_js_fallback("button[aria-label='Change when, for Bo Reyes']", expect_text: "Change place in Q2 settle instead")
      end
      click_link_with_js_fallback("Change place in Q2 settle instead", expect_text: "Moved to Q2 settle.")

      assert_text "Step 2 of 3"
      within("[data-timeline-phone]") { assert_selector "[data-timeline-lane]", text: /Bo\s+Reyes\s+to\s+Growth/ }
      assert_no_sideways_overflow
    end
  end

  [ [ "desktop", DESKTOP_SIZE ], [ "phone", MOBILE_SIZE ] ].each do |label, size|
    should "give a viewer no handles on a #{label}" do
      page.driver.browser.manage.window.resize_to(*size)
      sign_in_as(@viewer.user)
      visit timeline_plan_path(@plan_id)
      assert_text "Showing the path to Q2 settle."
      assert_no_selector "[draggable]"
      assert_no_selector "[data-timeline-shift-edge]"
      assert_no_button "Move…"
      assert_no_button "When…"
      assert_no_selector "[id^='move-person-modal']", visible: :all
    end
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
      const taken = !fire(target, "dragover")
      fire(target, "drop")
      fire(row, "dragend")
      return taken
    JS
  end

  # Real pointer input, so pointer capture and the controller's hit-testing run as they do for a person.
  def hold(grip, over:)
    page.driver.browser.action.move_to(grip.native).click_and_hold.move_to(find(over).native).perform
  end

  def release = page.driver.browser.action.release.perform

  def leaver_end_grip
    find(:xpath, "//*[@data-timeline-grid]//div[.//*[@data-timeline-lane][contains(normalize-space(.), 'leaves in Q1 hires')]]" \
                 "/span[@data-timeline-shift-edge='end']")
  end

  def fork(**params) = call(Operations::TeamPlanning::ForkScenario, @planner, plan_id: @plan_id, **params)[:scenario_id]

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

  # Ada and her backfill share Q1 hires, the step she leaves in.
  def assert_leaver_clear_of_backfill
    overlap = page.evaluate_script(<<~JS)
      (() => {
        const grid = document.querySelector("[data-timeline-grid]")
        const box = (text) => [...grid.querySelectorAll("[data-timeline-lane]")]
          .find((el) => el.textContent.includes(text)).getBoundingClientRect()
        const a = box("leaves in"), b = box("Replaces Ada Quill")
        return a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom
      })()
    JS
    assert_not overlap, "Ada's bar and her backfill's are drawn over each other"
  end
end
