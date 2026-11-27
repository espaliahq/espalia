# frozen_string_literal: true

require "test_helper"

# The organisation's own activity, read over MCP by leaving out unit_id, is for
# admins and Org Graph editors.
class OrgGraphOrganisationActivityMcpTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    @application = Mcp::Application.create!(name: "Test MCP Client", redirect_uri: "https://client.example/callback",
                                            scopes: "read write", confidential: false)
    ActsAsTenant.with_tenant(@tenant) do
      @admin = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant, name: "Ada Quill"))
      @member = create(:tenant_user, tenant: @tenant, role: :member, person: create(:person, tenant: @tenant))
      @editor = create(:tenant_user, tenant: @tenant, role: :member,
                                     person: create(:person, tenant: @tenant, name: "Brook Tamsin"))
      AccountGrants::CommandHandler.new.add(:org_graph_editor, @editor, added_by_id: @admin.person_id)
    end
  end

  should "give an admin the organisation's activity when unit_id is left out" do
    result = call_tool(@admin)

    payload = JSON.parse(result.dig("result", "content", 0, "text"))
    assert_nil payload["unit_id"]
    assert_equal [ "Made Brook Tamsin an Org Graph editor" ], payload["groups"].map { it["summary"] }
  end

  should "refuse a plain member" do
    assert_refused call_tool(@member)
  end

  should "give an Org Graph editor who isn't an admin the organisation's activity" do
    payload = JSON.parse(call_tool(@editor).dig("result", "content", 0, "text"))

    assert_equal [ "Made Brook Tamsin an Org Graph editor" ], payload["groups"].map { it["summary"] }
  end

  private

  def call_tool(tenant_user)
    token = Mcp::AccessToken.create!(application: @application, resource_owner_id: tenant_user.user_id, tenant_id: @tenant.id,
                                     scopes: "read write", expires_in: 3600)
    post mcp_server_path,
         params: { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "org_graph_activity", arguments: {} } }.to_json,
         headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{token.token}" }
    assert_response :success
    JSON.parse(response.body)
  end

  def assert_refused(body)
    assert_equal(-32603, body.dig("error", "code"), body.to_json)
    assert_match(/not authorized/, body.dig("error", "message"))
    assert_no_match(/Brook Tamsin/, body.to_json)
  end
end
