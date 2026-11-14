# frozen_string_literal: true

require "test_helper"

# A tenant default set over MCP waits for approval in the app, and the
# approval runs under the approver's own rights.
class PlanningRuleApprovalTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  class HeadcountCap < TeamPlanning::RuleKind
    def self.rule_name = "test_headcount_cap"
    def self.description = "The most people a unit may hold"
    def self.default = { cap: 10 }
  end

  setup do
    TeamPlanning::RuleKinds.register(HeadcountCap)
    @tenant = create(:tenant)
    @application = Mcp::Application.create!(name: "Test MCP Client", redirect_uri: "https://client.example/callback",
                                            scopes: "read write", confidential: false)
  end

  teardown { TeamPlanning::RuleKinds.unregister(HeadcountCap) }

  def account(role)
    user = create(:user)
    ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, user:, role:, person: create(:person, tenant: @tenant)) }
    user
  end

  def ask_over_mcp(user)
    token = Mcp::AccessToken.create!(application: @application, resource_owner_id: user.id, tenant_id: @tenant.id,
                                     scopes: "read write", expires_in: 3600)
    post mcp_server_path,
         params: { jsonrpc: "2.0", id: 1, method: "tools/call",
                   params: { name: "tenants_set_planning_rule", arguments: { rule: "test_headcount_cap", value: { cap: 4 } } } }.to_json,
         headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{token.token}" }
    Mcp::PendingApproval.find(JSON.parse(response.body).dig("result", "meta", "approvalId"))
  end

  def tenant_default = ActsAsTenant.with_tenant(@tenant) { PlanningRuleDefault.find_by(rule: "test_headcount_cap")&.value }

  should "wait for an admin's approval, then set the default" do
    admin = account(:admin)
    approval = ask_over_mcp(admin)
    assert_nil tenant_default

    sign_in admin
    post approve_mcp_approval_path(approval)

    assert_equal({ "cap" => 4 }, tenant_default)
    assert_equal "approved", approval.reload.status
  end

  should "refuse a member's approval, and set nothing" do
    member = account(:member)
    approval = ask_over_mcp(member)

    sign_in member
    post approve_mcp_approval_path(approval)

    assert_equal "You are not authorized to perform this operation.", flash[:alert]
    assert_nil tenant_default
  end
end
