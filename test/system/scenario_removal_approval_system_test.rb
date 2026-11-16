# frozen_string_literal: true

require "application_system_test_case"

# An editor who cannot see pay reviews a scenario removal sent over MCP: the
# page warns them, by count alone, of the pay changes it takes, and fits a phone.
class ScenarioRemovalApprovalSystemTest < ApplicationSystemTestCase
  AMOUNT = "92417"

  setup do
    @tenant = create(:tenant)
    ActsAsTenant.with_tenant(@tenant) do
      holder = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @editor = create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant))
      ada = create(:person, tenant: @tenant, name: "Ada Quill")
      OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
                              .record_person(ada.id, provider: "espalia", effective_on: (Date.current - 30).iso8601, employment_status: "employed", level: "3")
      plan_id = call(Operations::TeamPlanning::CreatePlan, holder, name: "Next year", base_on: (Date.current + 1).iso8601)[:plan_id]
      call(Operations::TeamPlanning::AddPlanMember, holder, plan_id:, person_id: @editor.person_id, role: "editor")
      q1 = call(Operations::TeamPlanning::ForkScenario, holder, plan_id:, relation: "then", name: "Q1", ends_on: (Date.current + 120).iso8601)[:scenario_id]
      call(Operations::TeamPlanning::SetActualPay, holder, plan_id:, scenario_id: q1, person_id: ada.id,
                                                           amount: AMOUNT, currency: "AUD", period: "year", basis: "full_time")
      application = Mcp::Application.create!(name: "Test MCP Client", redirect_uri: "https://client.example/callback",
                                             scopes: "read write", confidential: false)
      @approval = Mcp::PendingApproval.create!(tenant: @tenant, user: @editor.user, client_application: application,
                                               operation_class: "Operations::TeamPlanning::RemoveScenario",
                                               arguments: { plan_id:, scenario_id: q1 }, expires_at: 1.hour.from_now)
    end
  end

  [ [ "desktop", DESKTOP_SIZE ], [ "phone", MOBILE_SIZE ] ].each do |label, size|
    context "on a #{label}" do
      setup { page.driver.browser.manage.window.resize_to(*size) }

      should "warn of the pay changes by count, show no amount, and fit the screen" do
        sign_in_as @editor.user
        visit mcp_approval_path(@approval)

        assert_text "This scenario holds 1 change to pay you can't see. Removing it removes that too."
        assert_text "team_planning_remove_scenario"
        assert_no_pay_figure page.text, AMOUNT
        assert_no_sideways_overflow
      end
    end
  end

  private

  def call(operation, account, **params)
    operation.call(context: AuthorizationContext.new(user: account.user, tenant_user: account, person: account.person), params:)
  end
end
