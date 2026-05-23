# frozen_string_literal: true

require "test_helper"

# End-to-end test for the in-app approval handoff. Asserts that:
#   - an MCP tools/call against an :in_app Operation does NOT execute it;
#     it persists a PendingApproval row and returns an approval URL
#   - opening the URL as the same user renders the review page
#   - POST approve runs the deferred Operation and stamps the row
#   - POST reject marks the row without execution
#   - a different signed-in user can't open someone else's approval URL
#
# Whoami is hijacked into a :write + :in_app op so we don't need to ship
# a real high-stakes Operation purely to exercise this flow.
class McpInAppApprovalTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = create(:user, password: "password123")
    @tenant = create(:tenant, name: "Workspace A")

    ActsAsTenant.with_tenant(@tenant) do
      @person = create(:person, tenant: @tenant, email: @user.email, name: "Alice")
      @tenant_user = create(:tenant_user, tenant: @tenant, user: @user, person: @person, role: :member)
    end

    @application = Mcp::Application.create!(
      name: "Test MCP Client",
      redirect_uri: "https://client.example/callback",
      scopes: "read write",
      confidential: false
    )

    @token = Mcp::AccessToken.create!(
      application: @application,
      resource_owner_id: @user.id,
      tenant_id: @tenant.id,
      scopes: "read write",
      expires_in: 3600
    )

    # Re-tag Whoami as a write op that requires in-app approval for the
    # duration of this test class. perform stays read-only — we just want
    # to exercise the routing.
    @whoami = Operations::System::Whoami
    @original_category = @whoami.instance_variable_get(:@category)
    @original_approval = @whoami.instance_variable_get(:@approval)
    @whoami.instance_variable_set(:@category, :write)
    @whoami.instance_variable_set(:@approval, :in_app)
  end

  teardown do
    @whoami.instance_variable_set(:@category, @original_category)
    @whoami.instance_variable_set(:@approval, @original_approval)
  end

  def post_mcp(body, token: @token.token)
    post mcp_server_path,
      params: body.to_json,
      headers: {
        "Content-Type" => "application/json",
        "Authorization" => "Bearer #{token}"
      }
  end

  context "MCP tools/call against an :in_app Operation" do
    should "create a pending approval and return an approval URL instead of executing" do
      assert_difference -> { Mcp::PendingApproval.count }, 1 do
        post_mcp({
          jsonrpc: "2.0", id: 1, method: "tools/call",
          params: { name: "system_whoami", arguments: {} }
        })
      end

      assert_response :success
      body = JSON.parse(response.body)
      assert_match(/Approval required/, body.dig("result", "content", 0, "text"))
      assert_match(%r{/mcp/approvals/}, body.dig("result", "content", 0, "text"))
      assert body.dig("result", "meta", "approvalId").present?
      assert_match(%r{/mcp/approvals/}, body.dig("result", "meta", "approvalUrl"))

      approval = Mcp::PendingApproval.last
      assert_equal @user.id, approval.user_id
      assert_equal @tenant.id, approval.tenant_id
      assert_equal @application.id, approval.client_application_id
      assert_equal "Operations::System::Whoami", approval.operation_class
      assert_equal "pending", approval.status
    end
  end

  context "GET /mcp/approvals/:id" do
    setup do
      @approval = Mcp::PendingApproval.create!(
        user: @user, tenant: @tenant, client_application: @application,
        operation_class: "Operations::System::Whoami", arguments: {},
        expires_at: Time.current + 1.hour
      )
    end

    should "render the review page for the requesting user" do
      sign_in @user
      get mcp_approval_path(@approval)

      assert_response :success
      assert_match "MCP approval request", response.body
      assert_match "Test MCP Client", response.body
      assert_match "system_whoami", response.body
    end

    should "block another user from opening the approval URL" do
      other_user = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, user: other_user, role: :member) }

      sign_in other_user
      get mcp_approval_path(@approval)

      assert_redirected_to root_path
      assert_match(/Not found/, flash[:alert])
    end
  end

  context "POST /mcp/approvals/:id/approve" do
    setup do
      @approval = Mcp::PendingApproval.create!(
        user: @user, tenant: @tenant, client_application: @application,
        operation_class: "Operations::System::Whoami", arguments: {},
        expires_at: Time.current + 1.hour
      )
      sign_in @user
    end

    should "execute the deferred Operation and stamp the row" do
      post approve_mcp_approval_path(@approval)

      assert_redirected_to mcp_approval_path(@approval)
      @approval.reload
      assert_equal "approved", @approval.status
      assert @approval.executed_at.present?
      assert @approval.result_payload["value"].is_a?(Hash), "result not captured"
    end

    should "refuse re-approval after it has already been resolved" do
      @approval.update!(status: :rejected)
      post approve_mcp_approval_path(@approval)

      assert_redirected_to mcp_approval_path(@approval)
      assert_match(/Already rejected/, flash[:alert])
      @approval.reload
      assert_equal "rejected", @approval.status # untouched
    end
  end

  context "POST /mcp/approvals/:id/reject" do
    setup do
      @approval = Mcp::PendingApproval.create!(
        user: @user, tenant: @tenant, client_application: @application,
        operation_class: "Operations::System::Whoami", arguments: {},
        expires_at: Time.current + 1.hour
      )
      sign_in @user
    end

    should "mark the row rejected without executing" do
      post reject_mcp_approval_path(@approval)

      assert_redirected_to mcp_approval_path(@approval)
      @approval.reload
      assert_equal "rejected", @approval.status
      assert_nil @approval.executed_at
    end
  end
end
