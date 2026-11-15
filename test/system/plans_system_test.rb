# frozen_string_literal: true

require "application_system_test_case"

class PlansSystemTest < ApplicationSystemTestCase
  DESKTOP = DESKTOP_SIZE
  PHONE = MOBILE_SIZE

  setup do
    @tenant = create(:tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @planner = account(team_planner: true, name: "Erin Editor")
      @viewer = account(name: "Vic Viewer")
      @outsider = account(name: "Olly Outsider")
      @plan_id = call(Operations::TeamPlanning::CreatePlan, @planner, name: "Pay review 2027", base_on: "2026-11-14")[:plan_id]
      call(Operations::TeamPlanning::AddPlanMember, @planner, plan_id: @plan_id, person_id: @viewer.person.id, role: "viewer")
      q1 = call(Operations::TeamPlanning::ForkScenario, @planner, plan_id: @plan_id, relation: "then", name: "Q1 hires",
                                                                  ends_on: "2027-03-31")[:scenario_id]
      call(Operations::TeamPlanning::ForkScenario, @planner, plan_id: @plan_id, parent_id: q1, relation: "instead", name: "Slower hiring")
      call(Operations::TeamPlanning::ForkScenario, @planner, plan_id: @plan_id, parent_id: q1, relation: "then", name: "Q2 hires",
                                                             ends_on: "2027-06-30")
      structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
      department, squad = SecureRandom.uuid_v7, SecureRandom.uuid_v7
      structure.define_taxonomy([ { level_id: department, name: "Department" }, { level_id: squad, name: "Squad" } ], effective_on: "2026-01-01")
      engineering = SecureRandom.uuid_v7
      structure.create_unit(engineering, "Engineering", level_id: department, effective_on: "2026-01-01")
      structure.create_unit(SecureRandom.uuid_v7, "Payments", level_id: squad, parent_id: engineering, effective_on: "2026-01-01")
      structure.create_unit(SecureRandom.uuid_v7, "Sales", level_id: department, effective_on: "2026-01-01")
    end
  end

  [ [ "desktop", DESKTOP ], [ "phone", PHONE ] ].each do |label, size|
    context "on a #{label}" do
      setup { page.driver.browser.manage.window.resize_to(*size) }

      should "let a viewer open their plan and read its scenarios, rules and members" do
        sign_in_as(@viewer.user)
        visit plans_path
        assert_selector "h1", text: "Planning"
        assert_no_text "New plan"
        click_link_with_js_fallback("Pay review 2027", expect_text: "Private to 2 members")

        assert_text "You're a viewer."
        assert_text "Covers the whole organisation."
        assert_no_button "Change"
        assert_text "Based on the Org Graph on 14 November 2026"
        within("table") do
          assert_text "Today"
          assert_text "Read only"
          assert_text "As of 14 Nov 2026"
          assert_text "then Q1 hires"
          assert_text "instead Slower hiring"
          assert_text "then Q2 hires"
          assert_text "Apr to Jun 2027"
        end
        assert_text "This plan follows your organisation's defaults."
        within("aside") { assert_text "Erin Editor" }
        assert_no_sideways_overflow
      end

      should "let a planner start a plan and land on it" do
        sign_in_as(@planner.user)
        visit plans_path
        js_fill_in "Name", with: "Reorg 2027"
        click_button_with_js_fallback("Create plan", expect_text: "Reorg 2027")
        assert_text "Private to 1 member. You're an editor."
        assert_no_sideways_overflow
      end

      should "let a planner start a plan on the units they choose" do
        sign_in_as(@planner.user)
        visit plans_path
        assert_text "You can widen what a plan covers later."
        assert_no_selector "ul[aria-label='Units']"
        js_set_checkbox("Chosen units", checked: true)
        assert_selector "ul[aria-label='Units']", visible: true
        js_fill_in "Name", with: "Sales growth"
        js_set_checkbox("Sales", checked: true)
        click_button_with_js_fallback("Create plan", expect_text: "Covers Sales.")
        assert_text "Sales growth"
        assert_no_sideways_overflow
      end

      should "let an editor widen a plan from its page" do
        sign_in_as(@planner.user)
        visit plan_path(@plan_id)
        assert_text "Covers the whole organisation."
        wait_for_stimulus "modal"
        click_button_with_js_fallback("Change", expect_text: "What this plan covers")
        js_set_checkbox("Chosen units", checked: true)
        js_set_checkbox("Payments", checked: true)
        js_set_checkbox("Sales", checked: true)
        assert_no_sideways_overflow
        click_button_with_js_fallback("Save", expect_text: "This plan now covers Payments and Sales.")
        assert_text "Covers Payments and Sales."
      end

      should "tell a viewer their plan is frozen once its only editor is forgotten" do
        ActsAsTenant.with_tenant(@tenant) do
          @planner.person.update_columns(name: Person::FORMER_MEMBER, email: nil, forgotten_at: Time.current)
        end
        sign_in_as(@viewer.user)
        visit plan_path(@plan_id)

        assert_text "This plan is frozen"
        within("aside") do
          assert_text "Former member"
          assert_no_text "Erin Editor"
        end
        assert_no_sideways_overflow
      end

      should "show an outsider no plan, and no page for it" do
        sign_in_as(@outsider.user)
        visit plans_path
        assert_text "You're not in any plans yet"
        assert_no_text "Pay review 2027"
        assert_no_sideways_overflow
        visit plan_path(@plan_id)
        # The test environment shows Rails' error page, so the 404 reads as the exception that makes one.
        assert_text "ActiveRecord::RecordNotFound"
        [ "Pay review 2027", "Q1 hires", "Slower hiring", "Erin Editor" ].each { assert_no_text it }
      end
    end
  end

  private

  def account(role: :member, name: "Someone", **grants)
    user = create(:user, password: TEST_PASSWORD)
    person = create(:person, tenant: @tenant, name:, email: user.email)
    create(:tenant_user, tenant: @tenant, user:, role:, person:, **grants)
  end

  def call(operation, account, **params)
    context = AuthorizationContext.new(user: account.user, tenant_user: account, person: account.person)
    operation.call(context:, params:)
  end
end
