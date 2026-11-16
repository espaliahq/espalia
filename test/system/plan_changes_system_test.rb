# frozen_string_literal: true

require "application_system_test_case"

class PlanChangesSystemTest < ApplicationSystemTestCase
  ESPALIA = { provider: "espalia" }.freeze
  PLANNED_SETTLE = "[data-planned-change='conflicting'] [data-settle-conflict='level']"

  setup do
    @tenant = create(:tenant)
    handler = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    team = SecureRandom.uuid_v7
    @payments = SecureRandom.uuid_v7
    @growth = SecureRandom.uuid_v7

    # The plan is based a month back, so what the Org Graph learns today is drift.
    travel_to(30.days.ago) do
      since = Date.current.iso8601
      ActsAsTenant.with_tenant(@tenant) do
        @planner = account(team_planner: true, name: "Erin Editor")
        @viewer = account(name: "Vic Viewer")
        @ada = create(:person, tenant: @tenant, name: "Ada Quill")
        @bo = create(:person, tenant: @tenant, name: "Bo Reyes")
        structure.define_taxonomy([ { level_id: team, name: "Team" } ], effective_on: since)
        structure.create_unit(@payments, "Payments", level_id: team, effective_on: since)
        structure.create_unit(@growth, "Growth", level_id: team, effective_on: since)
        [ @ada, @bo ].each do |person|
          handler.record_person(person.id, **ESPALIA, effective_on: since, employment_status: "employed")
          handler.set_membership(person.id, @payments, **ESPALIA, effective_on: since, allocation: 1.0, role: "ENG")
        end
      end
      @plan_id = call(Operations::TeamPlanning::CreatePlan, @planner, name: "Pay review 2027", base_on: (Date.current + 1).iso8601)[:plan_id]
      call(Operations::TeamPlanning::AddPlanMember, @planner, plan_id: @plan_id, person_id: @viewer.person.id, role: "viewer")
      @q1 = call(Operations::TeamPlanning::ForkScenario, @planner, plan_id: @plan_id, relation: "then", name: "Q1 hires",
                                                                   ends_on: (Date.current + 120).iso8601)[:scenario_id]
      call(Operations::TeamPlanning::SetAssignment, @planner, plan_id: @plan_id, scenario_id: @q1, person_id: @bo.id,
                                                              placements: [ { unit_id: @growth, allocation: 1, role: "ENG" } ])
      call(Operations::TeamPlanning::SetRule, @planner, plan_id: @plan_id, scenario_id: @q1, unit_id: @payments, rule: "on_cost",
                                                        value: { "model" => "flat", "params" => { "percent" => "10" } })
    end

    today = Date.current.iso8601
    ActsAsTenant.with_tenant(@tenant) do
      handler.move_membership(@bo.id, @payments, @growth, effective_on: today)
      handler.change_title(@ada.id, "Staff Engineer", **ESPALIA, effective_on: today)
    end
  end

  context "on a desktop" do
    setup { page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE) }

    should "show what the Org Graph learned, the scenario each change meets, and where its plan stands" do
      sign_in_as(@viewer.user)
      visit plan_path(@plan_id)
      click_link_with_js_fallback("Changes", expect_text: "Needs attention")

      within("[data-changes-section='drift']") do
        assert_selector "[data-drift-change='moved']", text: "Bo Reyes moved from Payments to Growth"
        assert_selector "[data-drift-change='moved']", text: "Source: Espalia"
        assert_selector "[data-drift-change='fact_changed']", text: "Ada Quill's title is now Staff Engineer"
      end
      within("[data-changes-section='planned']") { assert_text "This scenario plans nothing yet." }
      assert_no_sideways_overflow

      click_selector_with_js_fallback("[data-drift-change='moved'] a[href='#{changes_plan_path(@plan_id, scenario: @q1)}']",
                                      expect_text: "Planned in Q1 hires")
      within("[data-changes-section='planned']") do
        assert_selector "nav[aria-label='Scenario'] a[aria-current='page']", text: "Q1 hires"
        assert_selector "[data-planned-change='done']", text: /Bo Reyes · Placement.*Done/m
        assert_selector "[data-planned-change='plan_only']", text: /Payments · Rule.*Plan only/m
      end
      click_selector_with_js_fallback("nav[aria-label='Scenario'] a[href='#{changes_plan_path(@plan_id)}']", expect_text: "Planned in Today")
    end

    should "let a planner write, rewrite and clear a change's note, which a viewer reads beside it" do
      sign_in_as(@planner.user)
      visit changes_plan_path(@plan_id, scenario: @q1)
      assert_selector "[data-planned-change='done']", text: "Bo Reyes"

      write_note("Agreed with **Bo** in the October 1:1", expect_text: "Note saved.")
      assert_selector "[data-planned-change='done'] [data-change-note] strong", text: "Bo"
      write_note("Moves once the Growth hire lands", expect_text: "Moves once the Growth hire lands")
      assert_no_text "Agreed with"

      write_note("", expect_text: "Note cleared.")
      assert_no_selector "[data-planned-change='done'] [data-change-note]"
      assert_selector "[data-change-note-editor] summary", text: "Add a note"
    end

    should "hold a long note to three lines until asked, without widening the row" do
      long_note_on_bo
      sign_in_as(@viewer.user)
      visit changes_plan_path(@plan_id, scenario: @q1)
      assert_clamped_note_opens
    end

    should "show a pay change's note to a member with the see-pay right, and neither the note nor its form to anyone else" do
      call(Operations::TeamPlanning::SetActualPay, @planner, plan_id: @plan_id, scenario_id: @q1, person_id: @ada.id,
                                                             amount: "93871", currency: "AUD", period: "year", basis: "full_time")
      pay_id = call(Operations::TeamPlanning::Status, @planner, plan_id: @plan_id, scenario_id: @q1)[:statuses]
               .find { it[:facet] == "data:pay" }[:change_id]
      call(Operations::TeamPlanning::NoteChange, @planner, plan_id: @plan_id, scenario_id: @q1, event_id: pay_id, note: "Matched to 93871")

      sign_in_as(@viewer.user)
      visit changes_plan_path(@plan_id, scenario: @q1)
      assert_selector "[data-planned-change='plan_only']", text: "Ada Quill"
      assert_no_text "Matched to"
      assert_no_selector "[data-planned-change] [data-change-note]"

      call(Operations::TeamPlanning::GrantSeePay, @planner, plan_id: @plan_id, person_id: @viewer.person.id)
      visit changes_plan_path(@plan_id, scenario: @q1)
      assert_selector "[data-planned-change='plan_only'] [data-change-note]", text: "Matched to 93871"
    end

    should "show a viewer the note but no way to change it" do
      call(Operations::TeamPlanning::NoteChange, @planner, plan_id: @plan_id, scenario_id: @q1, event_id: bo_change_id,
                                                           note: "Agreed in the October 1:1")
      sign_in_as(@viewer.user)
      visit changes_plan_path(@plan_id, scenario: @q1)
      assert_selector "[data-planned-change='done'] [data-change-note]", text: "Agreed in the October 1:1"
      assert_no_selector "[data-planned-change='done'] [data-change-note-editor]"
    end

    should "let an editor preview an update to today, confirm it, and see the conflict it carried" do
      plan_a_conflict
      sign_in_as(@planner.user)
      visit changes_plan_path(@plan_id)
      assert_text "Ada Quill's title is now Staff Engineer"
      click_link_with_js_fallback("Update to today", expect_text: "Conflicts it carries forward")

      within("[data-update-to-today]") do
        assert_selector "[data-update-scenario='#{@q1}']", text: /Q1 hires.*1 done.*1 conflicting/m
        assert_selector "[data-update-conflict='level']", text: "Ada Quill · Level in Q1 hires"
      end
      click_button_with_js_fallback("Update to #{today_label}", expect_text: "1 planned change stays conflicting.")
      assert_text "Updated to today, #{today_label}."
      assert_no_link "Update to today"

      visit changes_plan_path(@plan_id, scenario: @q1)
      assert_selector "[data-planned-change='conflicting']", text: /Ada Quill · Level.*Conflicting since/m
    end

    should "point a live conflict at the update, then settle a carried one in a child alone, and keep the plan in its parent" do
      plan_a_conflict
      lean = call(Operations::TeamPlanning::ForkScenario, @planner, plan_id: @plan_id, parent_id: @q1, relation: "instead",
                                                                    name: "Lean Q1")[:scenario_id]
      sign_in_as(@planner.user)
      visit changes_plan_path(@plan_id, scenario: @q1)
      assert_selector "[data-planned-change='conflicting'] [data-settle-conflict='live']", text: "Update the plan to today"
      assert_no_button "Keep the plan"

      carry_conflicts
      visit changes_plan_path(@plan_id, scenario: lean)
      assert_selector "[data-planned-change='conflicting'] [data-planned-in='#{@q1}'] a", text: "Q1 hires"
      click_selector_with_js_fallback("#{PLANNED_SETTLE} button[value='reality']", expect_text: "Following reality.")
      assert_no_selector "[data-planned-change='conflicting']"

      visit changes_plan_path(@plan_id, scenario: @q1)
      assert_selector "[data-planned-change='conflicting']", text: "Ada Quill"
      click_selector_with_js_fallback("#{PLANNED_SETTLE} button[value='plan']", expect_text: "Kept the plan.")
      assert_selector "[data-planned-change='pending']", text: /Ada Quill · Level/
      assert_no_selector "[data-planned-change='conflicting']"
    end

    should "settle a carried conflict from the drift row, which clears both rows' buttons at once" do
      plan_a_conflict
      carry_conflicts
      level_moves_again
      sign_in_as(@planner.user)
      visit changes_plan_path(@plan_id, scenario: @q1)
      assert_selector "[data-drift-settle='#{@q1}']", text: "Conflicts with the plan in Q1 hires."
      assert_selector PLANNED_SETTLE

      click_selector_with_js_fallback("[data-drift-settle='#{@q1}'] button[value='reality']", expect_text: "Following reality.")
      assert_no_selector "[data-drift-settle]"
      assert_no_selector "[data-settle-conflict]"
      assert_no_selector "[data-planned-change='conflicting']"
    end

    should "show a viewer a carried conflict with no way to settle it" do
      plan_a_conflict
      carry_conflicts
      sign_in_as(@viewer.user)
      visit changes_plan_path(@plan_id, scenario: @q1)
      assert_selector "[data-planned-change='conflicting']", text: /Ada Quill · Level.*Conflicting since/m
      assert_no_selector "[data-settle-conflict]"
    end

    should "offer a viewer no update to today" do
      sign_in_as(@viewer.user)
      visit changes_plan_path(@plan_id)
      assert_text "Bo Reyes moved from Payments to Growth"
      assert_no_link "Update to today"
    end
  end

  context "on a phone" do
    setup { page.driver.browser.manage.window.resize_to(*MOBILE_SIZE) }

    should "pick the scenario from a list and keep every row on screen" do
      sign_in_as(@viewer.user)
      visit changes_plan_path(@plan_id)
      assert_text "Bo Reyes moved from Payments to Growth"
      assert_no_selector "nav[aria-label='Scenario']", visible: true
      assert_no_sideways_overflow

      find("#changes-scenario").find("option", text: "Q1 hires").select_option
      assert_text "Planned in Q1 hires"
      assert_selector "[data-planned-change='done']", text: "Bo Reyes"
      assert_selector "[data-planned-change='plan_only']", text: "Plan only"
      assert_no_sideways_overflow
    end

    should "hold a long note to three lines on a phone until asked, without widening the page" do
      long_note_on_bo
      sign_in_as(@viewer.user)
      visit changes_plan_path(@plan_id, scenario: @q1)
      assert_clamped_note_opens
    end

    should "note a change in a form that fits, and mark a note erased with its person as removed, with no way to write another" do
      sign_in_as(@planner.user)
      visit changes_plan_path(@plan_id, scenario: @q1)
      assert_selector "[data-planned-change='done']", text: "Bo Reyes"

      write_note("Agreed in the October 1:1", expect_text: "Note saved.")
      assert_selector "[data-planned-change='done'] [data-change-note]", text: "Agreed in the October 1:1"
      assert_no_sideways_overflow

      ActsAsTenant.with_tenant(@tenant) { PlanKeyStore.new.destroy_person(@bo.id) }
      visit changes_plan_path(@plan_id, scenario: @q1)
      assert_selector "[data-planned-change='done'] [data-change-note='removed']", text: "Note removed"
      assert_no_text "Agreed in the October 1:1"
      assert_no_selector "[data-planned-change='done'] [data-change-note-editor]"
      assert_no_sideways_overflow
    end

    should "settle a carried conflict from the drift row's buttons, which fit, and clear both rows" do
      plan_a_conflict
      carry_conflicts
      level_moves_again
      sign_in_as(@planner.user)
      visit changes_plan_path(@plan_id, scenario: @q1)
      assert_selector PLANNED_SETTLE
      assert_selector "[data-drift-settle='#{@q1}']"
      assert_no_sideways_overflow

      click_selector_with_js_fallback("[data-drift-settle='#{@q1}'] button[value='plan']", expect_text: "Kept the plan.")
      # The kept plan meets the Org Graph's later move to 6, learned today, so it waits for the next update.
      assert_selector "[data-planned-change='conflicting'] [data-settle-conflict]", text: "settled after the next update"
      assert_no_selector "[data-drift-settle]"
      assert_no_selector "[data-settle-conflict] button"
      assert_no_sideways_overflow
    end

    should "preview and confirm an update to today in a page that fits" do
      plan_a_conflict
      sign_in_as(@planner.user)
      visit rebase_plan_path(@plan_id)
      assert_selector "[data-update-conflict='level']", text: "Ada Quill · Level in Q1 hires"
      assert_no_sideways_overflow

      click_button_with_js_fallback("Update to #{today_label}", expect_text: "1 planned change stays conflicting.")
      assert_no_link "Update to today"
      assert_no_sideways_overflow
    end
  end

  private

  def carry_conflicts
    base_on = call(Operations::TeamPlanning::Plan, @planner, plan_id: @plan_id)[:base_on]
    call(Operations::TeamPlanning::RebasePlan, @planner, plan_id: @plan_id, base_on:)
  end

  def plan_a_conflict
    call(Operations::TeamPlanning::SetPlannedLevel, @planner, plan_id: @plan_id, scenario_id: @q1, person_id: @ada.id, level: "4")
    # Learned before today, so an update to today takes it in: one learned today waits for the next.
    travel_to(2.days.ago) do
      ActsAsTenant.with_tenant(@tenant) do
        OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
                                .change_level(@ada.id, "5", **ESPALIA, effective_on: Date.current.iso8601)
      end
    end
  end

  # The update to today takes the first move into the baseline, so only a later one is drift.
  def level_moves_again
    ActsAsTenant.with_tenant(@tenant) do
      OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
                              .change_level(@ada.id, "6", **ESPALIA, effective_on: Date.current.iso8601)
    end
  end

  LONG_NOTE = ("Bo moves to Growth once the second hire lands and the on-call rota has a replacement for the weekend. " * 5) +
              "https://example.test/notes/#{'a' * 90}".freeze

  def long_note_on_bo
    call(Operations::TeamPlanning::NoteChange, @planner, plan_id: @plan_id, scenario_id: @q1, event_id: bo_change_id, note: LONG_NOTE)
  end

  def assert_clamped_note_opens
    note = "[data-planned-change='done'] [data-change-note]"
    assert_selector note, text: "Bo moves to Growth"
    assert_operator note_lines(note), :<=, 3
    assert_no_sideways_overflow

    click_selector_with_js_fallback("[data-planned-change='done'] [data-change-note-more] summary", expect_text: "Show less")
    assert_operator note_lines(note), :>, 3
    assert_no_sideways_overflow
  end

  def note_lines(selector)
    evaluate_script(<<~JS)
      (() => {
        const note = document.querySelector("#{selector}")
        return Math.round(note.getBoundingClientRect().height / parseFloat(getComputedStyle(note).lineHeight))
      })()
    JS
  end

  def today_label = I18n.l(Time.now.utc.to_date, format: "%-d %b %Y")

  def bo_change_id
    call(Operations::TeamPlanning::Status, @planner, plan_id: @plan_id, scenario_id: @q1)[:statuses]
      .find { it[:subject_id] == @bo.id }[:change_id]
  end

  def write_note(text, expect_text:)
    within("[data-planned-change='done']") do
      click_selector_with_js_fallback("[data-change-note-editor] summary", expect_text: "Leave it blank to clear the note.")
      js_fill_in "Note", with: text
    end
    click_button_with_js_fallback("Save note", expect_text:)
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
