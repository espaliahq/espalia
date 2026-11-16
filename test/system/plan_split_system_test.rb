# frozen_string_literal: true

require "application_system_test_case"

# Split the agreed part off a scenario from the plan page ([#360](https://github.com/espaliahq/espalia/issues/360)).
class PlanSplitSystemTest < ApplicationSystemTestCase
  ESPALIA = { provider: "espalia" }.freeze
  SYSTEM = OrgGraph::Authorization::SYSTEM

  setup do
    @tenant = create(:tenant)
    ActsAsTenant.with_tenant(@tenant) do
      squads = SecureRandom.uuid_v7
      payments = SecureRandom.uuid_v7
      org = OrgGraph::CommandHandler.new(actor: SYSTEM)
      structure = OrgGraph::StructureCommandHandler.new(actor: SYSTEM)
      ada = create(:person, tenant: @tenant, name: "Ada Quill")
      brook = create(:person, tenant: @tenant, name: "Brook Tamsin")
      structure.define_taxonomy([ { level_id: squads, name: "Squad" } ], effective_on: "2026-01-01")
      structure.create_unit(payments, "Payments", level_id: squads, effective_on: "2026-01-01")
      [ ada, brook ].each do
        org.record_person(it.id, **ESPALIA, effective_on: "2026-02-01", employment_status: "employed", title: "Engineer")
        org.set_membership(it.id, payments, **ESPALIA, effective_on: "2026-02-01", allocation: 1.0)
      end

      @planner = account(team_planner: true, name: "Erin Editor")
      @plan_id = call(Operations::TeamPlanning::CreatePlan, @planner, name: "Next year", base_on: "2026-03-02")[:plan_id]
      @q1 = call(Operations::TeamPlanning::ForkScenario, @planner, plan_id: @plan_id, relation: "then", name: "Q1 hires",
                                                                   ends_on: "2026-06-30")[:scenario_id]
      scenario = { plan_id: @plan_id, scenario_id: @q1 }
      call(Operations::TeamPlanning::SetUnit, @planner, **scenario, name: "Platform", top_level: true, level_id: squads)
      platform = ActsAsTenant.with_tenant(@tenant) { TeamPlanningOverride.where(facet: "unit").sole.subject_id }
      call(Operations::TeamPlanning::SetAssignment, @planner, **scenario, person_id: brook.id, placements: [ { unit_id: platform, allocation: 1.0 } ])
      call(Operations::TeamPlanning::SetAssignment, @planner, **scenario, person_id: ada.id, placements: [ { unit_id: payments, allocation: 0.5 } ])
    end
  end

  [ [ "desktop", DESKTOP_SIZE ], [ "phone", MOBILE_SIZE ] ].each do |label, size|
    context "on a #{label}" do
      setup { page.driver.browser.manage.window.resize_to(*size) }

      should "let an editor choose the agreed changes, see what one needs, and split them off" do
        sign_in_as(@planner.user)
        visit plan_path(@plan_id)
        assert_selector "h1", text: "Next year"
        row = "tr[data-scenario-id='#{@q1}']"
        open_dropdown(scope: row)
        click_link_with_js_fallback("Split off the agreed part…", expect_text: "Split Q1 hires")

        assert_text "Can't go across alone. It needs Platform: Unit"
        assert_no_sideways_overflow
        assert_button "Split off the chosen changes"
        wait_for_stimulus "split-count"
        js_set_checkbox "Brook Tamsin: Placement", checked: true
        assert_button "Split off 1 change"
        click_button_with_js_fallback("Split off 1 change", expect_text: "Couldn't split it")
        assert_text "Brook Tamsin: Placement needs Platform: Unit, which you left behind."
        assert_field "Brook Tamsin: Placement", checked: true

        assert_button "Split off 1 change"
        wait_for_stimulus "split-count"
        js_set_checkbox "Platform: Unit", checked: true
        assert_button "Split off 2 changes"
        js_fill_in "Name the agreed part", with: "Platform agreed"
        click_button_with_js_fallback("Split off 2 changes", expect_text: "Split 2 changes off into Platform agreed.")
        assert_text "Platform agreed"
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
    ActsAsTenant.with_tenant(@tenant) do
      operation.call(context: AuthorizationContext.new(user: account.user, tenant_user: account, person: account.person), params:)
    end
  end
end
