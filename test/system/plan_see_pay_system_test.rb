# frozen_string_literal: true

require "application_system_test_case"

class PlanSeePaySystemTest < ApplicationSystemTestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @planner = account(team_planner: true, name: "Erin Editor")
      @viewer = account(name: "Vic Viewer")
      @plan_id = call(Operations::TeamPlanning::CreatePlan, @planner, name: "Pay review 2027", base_on: "2026-11-14")[:plan_id]
      call(Operations::TeamPlanning::AddPlanMember, @planner, plan_id: @plan_id, person_id: @viewer.person.id, role: "viewer")
    end
  end

  [ [ "desktop", DESKTOP_SIZE ], [ "phone", MOBILE_SIZE ] ].each do |label, size|
    context "on a #{label}" do
      setup { page.driver.browser.manage.window.resize_to(*size) }

      should "let a holder give a member pay access, see who gave it, and withdraw it" do
        sign_in_as(@planner.user)
        visit plan_path(@plan_id)
        within("#plan-member-#{@planner.person.id}") { assert_text "Sees pay" }
        assert_no_selector "#plan-member-#{@planner.person.id} button"

        click_selector_with_js_fallback("#plan-member-#{@viewer.person.id} button", expect_text: "Vic Viewer can now see pay.")
        within("#plan-member-#{@viewer.person.id}") do
          assert_text "Sees pay"
          assert_text "Given by Erin Editor on #{Date.current.strftime('%-d %B %Y')}"
        end
        assert_no_sideways_overflow

        click_selector_with_js_fallback("#plan-member-#{@viewer.person.id} button", expect_text: "Vic Viewer can no longer see pay.")
        within("#plan-member-#{@viewer.person.id}") { assert_no_text "Sees pay" }
      end

      should "show a member without the right who holds it, and no controls" do
        sign_in_as(@viewer.user)
        visit plan_path(@plan_id)
        within("#plan-member-#{@planner.person.id}") { assert_text "Sees pay" }
        within("aside") { assert_no_selector "button", text: "pay access" }
        assert_no_sideways_overflow
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
