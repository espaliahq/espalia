# frozen_string_literal: true

require "application_system_test_case"

class PlanChangesOutsideSystemTest < ApplicationSystemTestCase
  ESPALIA = { provider: "espalia" }.freeze
  ROW = "[data-planned-change='outside']"

  setup do
    @tenant = create(:tenant)
    people = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    departments = SecureRandom.uuid_v7
    @engineering, @sales = Array.new(2) { SecureRandom.uuid_v7 }

    # The baseline reads the Org Graph as known the day before the base, so these land well before it.
    travel_to(30.days.ago) do
      since = Date.current.iso8601
      ActsAsTenant.with_tenant(@tenant) do
        @editor = account(team_planner: true, name: "Erin Editor")
        @viewer = account(name: "Vic Viewer")
        @dee = create(:person, tenant: @tenant, name: "Dee Quill")
        structure.define_taxonomy([ { level_id: departments, name: "Department" } ], effective_on: since)
        structure.create_unit(@engineering, "Engineering", level_id: departments, effective_on: since)
        structure.create_unit(@sales, "Sales", level_id: departments, effective_on: since)
        people.record_person(@dee.id, **ESPALIA, effective_on: since, employment_status: "employed", level: "3")
        people.set_membership(@dee.id, @sales, **ESPALIA, effective_on: since, allocation: 1.0)
      end
    end

    @plan_id = call(Operations::TeamPlanning::CreatePlan, @editor, name: "Engineering next year", base_on: Date.current.iso8601,
                                                                   unit_ids: [ @engineering ])[:plan_id]
    call(Operations::TeamPlanning::AddPlanMember, @editor, plan_id: @plan_id, person_id: @viewer.person.id, role: "viewer")
    @q1 = call(Operations::TeamPlanning::ForkScenario, @editor, plan_id: @plan_id, relation: "then", name: "Q1",
                                                                ends_on: (Date.current + 120).iso8601)[:scenario_id]
    call(Operations::TeamPlanning::SetAssignment, @editor, plan_id: @plan_id, scenario_id: @q1, person_id: @dee.id,
                                                           placements: [ { unit_id: @engineering, allocation: 1 } ])
    call(Operations::TeamPlanning::SetPlannedLevel, @editor, plan_id: @plan_id, scenario_id: @q1, person_id: @dee.id, level: "4")
    call(Operations::TeamPlanning::ClearChange, @editor, plan_id: @plan_id, scenario_id: @q1, subject_id: @dee.id, facet: "assignment")
  end

  context "on a desktop" do
    setup { page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE) }

    should "offer an editor Clear and Undo on a change about someone the plan no longer covers, naming no one" do
      sign_in_as(@editor.user)
      visit changes_plan_path(@plan_id, scenario: @q1)

      within(ROW) do
        assert_text "Someone this plan no longer covers"
        assert_selector "button", text: "Clear"
        assert_selector "button", text: "Undo"
        assert_no_selector "[data-settle-conflict]"
      end
      assert_no_text "Dee Quill"

      click_button_with_js_fallback("Clear", expect_text: "Change cleared.")
      assert_no_selector ROW
    end

    should "show a viewer the row with no way to change it" do
      sign_in_as(@viewer.user)
      visit changes_plan_path(@plan_id, scenario: @q1)

      assert_selector ROW, text: "Someone this plan no longer covers"
      assert_no_selector "#{ROW} button"
      assert_no_text "Dee Quill"
    end
  end

  context "on a phone" do
    setup { page.driver.browser.manage.window.resize_to(*MOBILE_SIZE) }

    should "undo the change from buttons that fit" do
      sign_in_as(@editor.user)
      visit changes_plan_path(@plan_id, scenario: @q1)

      assert_selector "#{ROW} button", text: "Undo"
      assert_no_sideways_overflow

      click_button_with_js_fallback("Undo", expect_text: "Change undone.")
      assert_no_selector ROW
    end
  end

  private

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
