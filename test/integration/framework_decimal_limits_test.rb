# frozen_string_literal: true

require "test_helper"

# A decimal its numeric(5, 2) column would round reaches the person as a
# refusal naming the limit, on the web form and over MCP, never as a 500.
class FrameworkDecimalLimitsTest < ActionDispatch::IntegrationTest
  LIMIT = /must be below 1000 with at most two decimal places/

  setup do
    @tenant = create(:tenant)
    @admin = create(:user, password: "password123")
    @application = Mcp::Application.create!(name: "Test MCP Client", redirect_uri: "https://client.example/callback",
                                            scopes: "read write", confidential: false)

    ActsAsTenant.with_tenant(@tenant) do
      create(:tenant_user, tenant: @tenant, user: @admin, role: :admin, person: create(:person, tenant: @tenant, email: @admin.email))

      @framework_id = SecureRandom.uuid_v7
      @cap_id = SecureRandom.uuid_v7
      @role_a = SecureRandom.uuid_v7
      @role_b = SecureRandom.uuid_v7
      @binding_id = SecureRandom.uuid_v7
      handler = Frameworks::CommandHandler.new
      handler.create_framework(@framework_id, "Eng")
      family_id = SecureRandom.uuid_v7
      handler.add_role_family(@framework_id, family_id, "Engineering")
      handler.add_role(@framework_id, @role_a, family_id, "Software Engineer", "E", "ic")
      handler.add_role(@framework_id, @role_b, family_id, "Engineering Manager", "EM", "management")
      category_id = SecureRandom.uuid_v7
      handler.add_capability_category(@framework_id, category_id, "Thinking")
      handler.add_capability(@framework_id, @cap_id, SecureRandom.uuid_v7, category_id, "Critical Thinking")
      handler.create_capability_role_binding(@framework_id, @binding_id, @cap_id, @role_a, weight: 1.0)
      handler.publish_version(@framework_id, "seed")
    end
  end

  def sign_in_admin
    post user_session_path, params: { user: { email: @admin.email, password: "password123" } }
  end

  def call_tool(name, arguments)
    token = Mcp::AccessToken.create!(application: @application, resource_owner_id: @admin.id, tenant_id: @tenant.id,
                                     scopes: "read write", expires_in: 3600)
    post mcp_server_path,
         params: { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name:, arguments: } }.to_json,
         headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{token.token}" }
    JSON.parse(response.body)
  end

  context "adding a binding" do
    should "refuse on the web form" do
      sign_in_admin
      post framework_capability_bindings_path(framework_id: @framework_id),
           params: { binding: { capability_id: @cap_id, role_id: @role_b, weight: "1.234" } }

      assert_response :unprocessable_content
      assert_match LIMIT, response.body
    end

    should "refuse over MCP" do
      body = call_tool("frameworks_add_capability_role_binding",
                       { framework_id: @framework_id, capability_id: @cap_id, role_id: @role_b, weight: 1.234 })

      assert_equal(-32_602, body.dig("error", "code"))
      assert_match LIMIT, body.dig("error", "message")
    end
  end

  context "changing a binding" do
    should "refuse on the web form" do
      sign_in_admin
      patch framework_capability_binding_path(framework_id: @framework_id, id: @binding_id),
            params: { binding: { weight: "1.234" } }

      assert_response :unprocessable_content
      assert_match LIMIT, response.body
    end

    should "refuse over MCP" do
      body = call_tool("frameworks_update_capability_role_binding",
                       { framework_id: @framework_id, binding_id: @binding_id, weight: 1.234 })

      assert_equal(-32_602, body.dig("error", "code"))
      assert_match LIMIT, body.dig("error", "message")
    end
  end

  context "configuring scoring thresholds" do
    should "refuse on the web form" do
      sign_in_admin
      patch framework_settings_path(framework_id: @framework_id), params: { settings: { mastery_threshold: "1.234" } }

      assert_redirected_to framework_settings_path(framework_id: @framework_id)
      assert_match LIMIT, flash[:alert]
    end

    should "refuse over MCP when the approval runs" do
      body = call_tool("frameworks_configure_scoring_thresholds",
                       { framework_id: @framework_id, meeting_expectation_threshold: 1.234 })
      approval = Mcp::PendingApproval.find(body.dig("result", "meta", "approvalId"))

      sign_in_admin
      post approve_mcp_approval_path(approval)

      assert_redirected_to mcp_approval_path(approval)
      assert_match(/\AMeeting expectation threshold #{LIMIT.source}/, flash[:alert])
      assert_equal "pending", approval.reload.status
    end
  end
end
