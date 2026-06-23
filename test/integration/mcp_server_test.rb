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

    should "execute frameworks_list and return tenant-scoped framework rows" do
      ActsAsTenant.with_tenant(@tenant) do
        create(:framework_state, tenant: @tenant, framework_id: SecureRandom.uuid_v7,
               name: "Engineering", current_published_version: 2)
        create(:framework_state, tenant: @tenant, framework_id: SecureRandom.uuid_v7,
               name: "Apprenticeship", current_published_version: 1)
      end

      post_mcp({
        jsonrpc: "2.0", id: 100, method: "tools/call",
        params: { name: "frameworks_list", arguments: {} }
      })

      assert_response :success
      content = json_body.dig("result", "content")
      assert content, "tools/call body was: #{response.body}"
      payload = JSON.parse(content.first["text"])
      assert_equal %w[Apprenticeship Engineering], payload.map { |r| r["name"] }
      assert_equal [ 1, 2 ], payload.map { |r| r["current_published_version"] }
    end

    should "execute assessments_mine and return the caller's own + report rows" do
      framework_id = nil
      report_person = nil
      ActsAsTenant.with_tenant(@tenant) do
        report_person = create(:person, tenant: @tenant, manager_id: @person.id, name: "Bob")
        framework_id = SecureRandom.uuid_v7
        create(:framework_state, framework_id: framework_id, name: "Engineering")
        rf = create(:framework_role_family, framework_id: framework_id, name: "Eng")
        role  = create(:framework_role, role_family_id: rf.role_family_id, name: "SWE", code: "E", track: "ic")
        level = create(:framework_level, role_id: role.role_id, ordinal: 2, title: "Mid", code: "E2")

        handler = PersonDevelopment::CommandHandler.new
        handler.assign_to_framework(@person.id,       framework_id, role.role_id, level.level_id)
        handler.assign_to_framework(report_person.id, framework_id, role.role_id, level.level_id)
      end

      post_mcp({
        jsonrpc: "2.0", id: 200, method: "tools/call",
        params: { name: "assessments_mine", arguments: {} }
      })

      assert_response :success
      payload = JSON.parse(json_body.dig("result", "content", 0, "text"))
      assert_equal 1, payload["own"].size
      assert_equal "Engineering", payload.dig("own", 0, "framework", "name")
      assert_equal [ "Bob" ], payload["direct_reports"].map { |r| r.dig("assessee", "name") }
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

    # Regression: pre-fix this returned -32603 "internal error" with the
    # full SQL fragment in the log + on the wire. The classification is
    # important so Datadog error monitors scoped to MCP only fire on
    # genuine server bugs.
    should "return JSON-RPC -32602 (not -32603) when a client-supplied id doesn't resolve" do
      post_mcp({
        jsonrpc: "2.0", id: 5, method: "tools/call",
        params: {
          name: "frameworks_capability_get",
          arguments: { framework_id: SecureRandom.uuid_v7, capability_id: SecureRandom.uuid_v7 }
        }
      })

      assert_response :success
      err = json_body["error"]
      assert_equal(-32602, err["code"])
      assert_match(/not found/, err["message"])
      assert_no_match(/WHERE/, err["message"], "should not leak the SQL fragment in the response")
    end

    # Regression (alpha-tester report): a malformed external_reference threw
    # ActiveModel::UnknownAttributeError out of the operation, surfacing as a
    # -32603 "internal error". A bad payload is the client's fault, so it must
    # classify as -32602 invalid-params — the evidence-write tools validate it
    # upfront. Here a non-object value trips the param type check; an unknown
    # *key* takes the same ParameterError path (covered at the operation layer).
    should "classify a malformed external_reference as -32602, not -32603" do
      post_mcp({
        jsonrpc: "2.0", id: 7, method: "tools/call",
        params: {
          name: "assessments_record_evidence",
          arguments: {
            assignment_id: SecureRandom.uuid_v7,
            capability_stable_id: SecureRandom.uuid_v7,
            level_ordinal: 2,
            evidence_type: "code_review",
            content: "x",
            external_reference: "not-an-object"
          }
        }
      })

      assert_response :success
      err = json_body["error"]
      assert_equal(-32602, err["code"])
      assert_no_match(/internal error/, err["message"])
    end
  end

  context "audit metadata" do
    # Replaces Whoami.perform with a probe that snapshots AuditMetadata.current
    # at execution time, so we verify the actual thread-local set by the
    # MCP controller — not just that `AuditMetadata.with` was called with
    # the right kwargs (which could pass even if the seed never landed).
    should "make acting_via :mcp + the token's application_id visible to the running tool" do
      observed = nil
      Operations::System::Whoami.class_eval do
        alias_method :_original_perform, :perform
        define_method(:perform) do
          observed = AuditMetadata.current
          { ok: true }
        end
      end

      begin
        post_mcp({
          jsonrpc: "2.0", id: 6, method: "tools/call",
          params: { name: "system_whoami", arguments: {} }
        })
      ensure
        Operations::System::Whoami.class_eval do
          alias_method :perform, :_original_perform
          remove_method :_original_perform
        end
      end

      # Force the assertion to close over the observed binding the lambda
      # writes into — this is the load-bearing check: the controller's
      # `AuditMetadata.with` actually mutated the thread-local during the
      # dispatch, not just that some kwargs got forwarded to a stub.
      assert observed, "AuditMetadata.current was never observed"
      assert_equal :mcp,            observed[:acting_via]
      assert_equal @application.id, observed[:client_application_id]
      assert_response :success
    end
  end

  context "scope enforcement" do
    setup do
      @read_only_token = Mcp::AccessToken.create!(
        application: @application,
        resource_owner_id: @user.id,
        tenant_id: @tenant.id,
        scopes: "read",
        expires_in: 3600
      )
    end

    should "allow a read tool with a read-only token" do
      post_mcp(
        {
          jsonrpc: "2.0", id: 10, method: "tools/call",
          params: { name: "system_whoami", arguments: {} }
        },
        token: @read_only_token.token
      )

      assert_response :success
      assert_nil json_body["error"]
      assert json_body.dig("result", "content")
    end

    # Use a stubbed Operations subclass redefined inline so we don't need
    # to ship a real write Operation purely to exercise the scope check.
    should "reject a write tool with a read-only token" do
      whoami = Operations::System::Whoami
      original_category = whoami.instance_variable_get(:@category)
      whoami.instance_variable_set(:@category, :write)

      begin
        post_mcp(
          {
            jsonrpc: "2.0", id: 11, method: "tools/call",
            params: { name: "system_whoami", arguments: {} }
          },
          token: @read_only_token.token
        )
      ensure
        whoami.instance_variable_set(:@category, original_category)
      end

      assert_response :success
      err = json_body["error"]
      assert_equal(-32603, err["code"])
      assert_match(/insufficient scope/, err["message"])
      assert_match(/write/, err["message"])
    end
  end

  context "resources/list + resources/read" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        framework_id = SecureRandom.uuid_v7
        create(:framework_state, framework_id: framework_id, name: "Engineering")
        rf = create(:framework_role_family, framework_id: framework_id, name: "Eng")
        role  = create(:framework_role, role_family_id: rf.role_family_id, name: "SWE", code: "E", track: "ic")
        level = create(:framework_level, role_id: role.role_id, ordinal: 2, title: "Mid", code: "E2")
        create(:framework_capability_category, framework_id: framework_id, name: "Thinking", ordinal: 1)

        PersonDevelopment::CommandHandler.new
          .assign_to_framework(@person.id, framework_id, role.role_id, level.level_id)
        @resource_framework_id = framework_id
        @resource_assignment   = PersonFrameworkAssignment.for_person(@person.id).first
      end
    end

    should "list framework:// and assessment:// resources visible to the caller" do
      post_mcp({ jsonrpc: "2.0", id: 300, method: "resources/list" })

      assert_response :success
      resources = json_body.dig("result", "resources")
      uris = resources.map { |r| r["uri"] }
      assert_includes uris, "framework://#{@resource_framework_id}"
      assert_includes uris, "assessment://#{@resource_assignment.id}"
    end

    should "read a framework:// resource and return the Frameworks::Get payload" do
      post_mcp({
        jsonrpc: "2.0", id: 301, method: "resources/read",
        params: { uri: "framework://#{@resource_framework_id}" }
      })

      assert_response :success
      contents = json_body.dig("result", "contents")
      assert_equal 1, contents.size
      assert_equal "application/json", contents.first["mimeType"]
      payload = JSON.parse(contents.first["text"])
      assert_equal "Engineering", payload["name"]
      assert_equal [ "Thinking" ], payload["categories"].map { |c| c["name"] }
    end

    should "read an assessment:// resource and return the Assessments::Get payload" do
      post_mcp({
        jsonrpc: "2.0", id: 302, method: "resources/read",
        params: { uri: "assessment://#{@resource_assignment.id}" }
      })

      assert_response :success
      payload = JSON.parse(json_body.dig("result", "contents", 0, "text"))
      assert_equal "Engineering", payload.dig("framework", "name")
      assert_equal @resource_assignment.id, payload.dig("assignment", "id")
    end

    should "return JSON-RPC -32601 for an unknown resource URI" do
      post_mcp({
        jsonrpc: "2.0", id: 303, method: "resources/read",
        params: { uri: "junk://nope" }
      })

      assert_response :success
      err = json_body["error"]
      assert_equal(-32601, err["code"])
    end
  end

  context "initialize advertises resources capability" do
    should "include resources alongside tools in capabilities" do
      post_mcp({ jsonrpc: "2.0", id: 400, method: "initialize" })

      assert_response :success
      caps = json_body.dig("result", "capabilities")
      assert caps["tools"].is_a?(Hash)
      assert caps["resources"].is_a?(Hash)
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
