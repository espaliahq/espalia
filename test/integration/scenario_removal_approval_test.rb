# frozen_string_literal: true

require "test_helper"

# Removing a scenario over MCP waits for approval in the app. An editor who
# cannot see pay learns, by count alone, that the scenario holds pay changes
# their removal takes with it
# ([#322](https://github.com/espaliahq/espalia/pull/322)).
class ScenarioRemovalApprovalTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  AMOUNT = "92417"

  setup do
    travel_to Time.utc(2026, 2, 1, 9)
    @tenant = create(:tenant)
    @application = Mcp::Application.create!(name: "Test MCP Client", redirect_uri: "https://client.example/callback",
                                            scopes: "read write", confidential: false)
    ActsAsTenant.with_tenant(@tenant) do
      @holder = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @editor = create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant))
      ada = create(:person, tenant: @tenant, name: "Ada Quill")
      OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
                              .record_person(ada.id, provider: "espalia", effective_on: "2026-02-01", employment_status: "employed", level: "3")
      @plan_id = call(Operations::TeamPlanning::CreatePlan, @holder, name: "Next year", base_on: "2026-03-02")[:plan_id]
      call(Operations::TeamPlanning::AddPlanMember, @holder, plan_id: @plan_id, person_id: @editor.person_id, role: "editor")
      @q1 = call(Operations::TeamPlanning::ForkScenario, @holder, plan_id: @plan_id, relation: "then", name: "Q1", ends_on: "2026-06-30")[:scenario_id]
      [ @plan_id, @q1 ].each do |scenario_id|
        call(Operations::TeamPlanning::SetActualPay, @holder, plan_id: @plan_id, scenario_id:, person_id: ada.id,
                                                              amount: AMOUNT, currency: "AUD", period: "year", basis: "full_time")
      end
    end
  end

  should "tell an editor without the right how many pay changes go with the scenario, and no more" do
    approval = ask_over_mcp(@editor)
    sign_in @editor.user
    get mcp_approval_path(approval)

    assert_response :success
    assert_includes response.body, "This scenario holds 1 change to pay you can&#39;t see."
    assert_not_includes response.body, AMOUNT

    post approve_mcp_approval_path(approval)
    assert_equal "approved", approval.reload.status
    assert_not_includes approval.result_payload.to_json, AMOUNT
    ActsAsTenant.with_tenant(@tenant) do
      assert_includes call(Operations::TeamPlanning::ScenarioMap, @holder, plan_id: @plan_id, scenario_id: @plan_id).to_json, AMOUNT
    end
  end

  should "show a holder no notice, since they see the pay itself" do
    approval = ask_over_mcp(@holder)
    sign_in @holder.user
    get mcp_approval_path(approval)

    assert_response :success
    assert_not_includes response.body, "you can&#39;t see"
  end

  should "still show the page when the notice fails" do
    approval = ask_over_mcp(@editor)
    sign_in @editor.user
    Operations::TeamPlanning::RemoveScenario.stub(:approval_notice, ->(**) { raise "boom" }) { get mcp_approval_path(approval) }

    assert_response :success
    assert_includes response.body, "Approve"
  end

  private

  def ask_over_mcp(account)
    token = Mcp::AccessToken.create!(application: @application, resource_owner_id: account.user_id, tenant_id: @tenant.id,
                                     scopes: "read write", expires_in: 3600)
    post mcp_server_path,
         params: { jsonrpc: "2.0", id: 1, method: "tools/call",
                   params: { name: "team_planning_remove_scenario", arguments: { plan_id: @plan_id, scenario_id: @q1 } } }.to_json,
         headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{token.token}" }
    Mcp::PendingApproval.find(JSON.parse(response.body).dig("result", "meta", "approvalId"))
  end

  def call(operation, account, **params)
    operation.call(context: AuthorizationContext.new(user: account.user, tenant_user: account, person: account.person), params:)
  end
end
