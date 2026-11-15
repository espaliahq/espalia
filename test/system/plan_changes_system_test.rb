# frozen_string_literal: true

require "application_system_test_case"

class PlanChangesSystemTest < ApplicationSystemTestCase
  ESPALIA = { provider: "espalia" }.freeze

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
      assert_selector "[data-planned-change] [data-change-note] strong", text: "Bo"
      write_note("Moves once the Growth hire lands", expect_text: "Moves once the Growth hire lands")
      assert_no_text "Agreed with"

      write_note("", expect_text: "Note cleared.")
      assert_no_selector "[data-change-note]"
      assert_selector "[data-change-note-editor] summary", text: "Add a note"
    end

    should "show a viewer the note but no way to change it" do
      call(Operations::TeamPlanning::NoteChange, @planner, plan_id: @plan_id, scenario_id: @q1, event_id: bo_change_id,
                                                           note: "Agreed in the October 1:1")
      sign_in_as(@viewer.user)
      visit changes_plan_path(@plan_id, scenario: @q1)
      assert_selector "[data-planned-change] [data-change-note]", text: "Agreed in the October 1:1"
      assert_no_selector "[data-change-note-editor]"
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

    should "note a change in a form that fits, and mark a note erased with its person as removed, with no way to write another" do
      sign_in_as(@planner.user)
      visit changes_plan_path(@plan_id, scenario: @q1)
      assert_selector "[data-planned-change='done']", text: "Bo Reyes"

      write_note("Agreed in the October 1:1", expect_text: "Note saved.")
      assert_selector "[data-planned-change] [data-change-note]", text: "Agreed in the October 1:1"
      assert_no_sideways_overflow

      ActsAsTenant.with_tenant(@tenant) { PlanKeyStore.new.destroy_person(@bo.id) }
      visit changes_plan_path(@plan_id, scenario: @q1)
      assert_selector "[data-planned-change] [data-change-note='removed']", text: "Note removed"
      assert_no_text "Agreed in the October 1:1"
      assert_no_selector "[data-change-note-editor]"
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

  def plan_a_conflict
    call(Operations::TeamPlanning::SetPlannedLevel, @planner, plan_id: @plan_id, scenario_id: @q1, person_id: @ada.id, level: "4")
    ActsAsTenant.with_tenant(@tenant) do
      OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
                              .change_level(@ada.id, "5", **ESPALIA, effective_on: Date.current.iso8601)
    end
  end

  def today_label = I18n.l(Time.now.utc.to_date, format: "%-d %b %Y")

  def bo_change_id
    call(Operations::TeamPlanning::Status, @planner, plan_id: @plan_id, scenario_id: @q1)[:statuses].sole[:change_id]
  end

  def write_note(text, expect_text:)
    within("[data-planned-change]") do
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
