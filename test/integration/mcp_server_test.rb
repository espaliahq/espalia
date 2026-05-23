# frozen_string_literal: true

require "test_helper"

# End-to-end JSON-RPC checks for the MCP server. Mints a Doorkeeper token
# directly (bypassing the OAuth UI — that flow is covered separately by
# OauthPkceFlowTest) and POSTs each JSON-RPC method to /mcp.
#
# Validates:
#   - bearer auth (401 without token, 200 with)
#   - tenant resolution from the token's tenant_id
#   - `initialize`, `tools/list`, `tools/call` round trips
#   - the Whoami tool exists and returns the caller's identity
#   - unknown methods/tools map to the right JSON-RPC error codes
class McpServerTest < ActionDispatch::IntegrationTest
  setup do
    @user = create(:user, password: "password123")
    @tenant = create(:tenant, name: "Workspace A")
    @other_tenant = create(:tenant, name: "Workspace B")

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
  end

  # Helper: POSTs a JSON-RPC payload with the bearer token.
  def post_mcp(body, token: @token.token)
    headers = { "Content-Type" => "application/json" }
    headers["Authorization"] = "Bearer #{token}" if token

    post mcp_server_path, params: body.to_json, headers: headers
  end

  def json_body
    JSON.parse(response.body)
  end

  context "auth" do
    should "return 401 without a bearer token" do
      post mcp_server_path,
        params: { jsonrpc: "2.0", id: 1, method: "initialize" }.to_json,
        headers: { "Content-Type" => "application/json" }

      assert_response :unauthorized
    end

    should "return 401 with an invalid bearer token" do
      post_mcp({ jsonrpc: "2.0", id: 1, method: "initialize" }, token: "not-a-real-token")
      assert_response :unauthorized
    end
  end

  context "initialize" do
    should "return serverInfo and protocolVersion" do
      post_mcp({ jsonrpc: "2.0", id: 1, method: "initialize" })

      assert_response :success
      body = json_body
      assert_equal "2.0", body["jsonrpc"]
      assert_equal 1, body["id"]
      assert_equal Mcp::RequestHandler::PROTOCOL_VERSION, body.dig("result", "protocolVersion")
      assert_equal "growth_os", body.dig("result", "serverInfo", "name")
      assert body.dig("result", "capabilities", "tools").is_a?(Hash)
    end
  end

  context "tools/list" do
    should "include the Whoami tool with read-only annotations" do
      post_mcp({ jsonrpc: "2.0", id: 2, method: "tools/list" })

      assert_response :success
      tools = json_body.dig("result", "tools")
      whoami = tools.find { |t| t["name"] == "system_whoami" }

      assert whoami, "system_whoami tool missing from tools/list"
      assert_match(/Identify the user/, whoami["description"])
      assert_equal true, whoami.dig("annotations", "readOnlyHint")
      assert_equal false, whoami.dig("annotations", "destructiveHint")
      assert_equal "object", whoami.dig("inputSchema", "type")
    end
  end

  context "tools/call" do
    should "execute the Whoami tool against the token's resource owner and tenant" do
      post_mcp({
        jsonrpc: "2.0", id: 3, method: "tools/call",
        params: { name: "system_whoami", arguments: {} }
      })

      assert_response :success
      content = json_body.dig("result", "content")
      assert_equal 1, content.length
      assert_equal "text", content.first["type"]

      payload = JSON.parse(content.first["text"])
      assert_equal @user.id, payload.dig("user", "id")
      assert_equal @user.email, payload.dig("user", "email")
      assert_equal @tenant.id, payload.dig("tenant", "id")
      assert_equal "Workspace A", payload.dig("tenant", "name")
      assert_equal "member", payload.dig("tenant", "role")
      assert_equal @person.id, payload.dig("person", "id")
    end

    should "return JSON-RPC -32601 for an unknown tool" do
      post_mcp({
        jsonrpc: "2.0", id: 4, method: "tools/call",
        params: { name: "does_not_exist", arguments: {} }
      })

      assert_response :success
      err = json_body["error"]
      assert_equal(-32601, err["code"])
      assert_match(/unknown tool/, err["message"])
    end
  end

  context "protocol errors" do
    should "return JSON-RPC -32601 for an unknown method" do
      post_mcp({ jsonrpc: "2.0", id: 5, method: "does/not/exist" })

      assert_response :success
      err = json_body["error"]
      assert_equal(-32601, err["code"])
    end

    should "return JSON-RPC -32700 for malformed JSON" do
      post mcp_server_path,
        params: "not json {{{",
        headers: {
          "Content-Type" => "application/json",
          "Authorization" => "Bearer #{@token.token}"
        }

      assert_response :bad_request
      err = json_body["error"]
      assert_equal(-32700, err["code"])
    end
  end
end
