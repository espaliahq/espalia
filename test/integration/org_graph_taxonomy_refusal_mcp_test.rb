# frozen_string_literal: true

require "test_helper"

# The taxonomy tools wait for approval in the app, and refuse there from their
# policy step, before the command runs, with the command's own sentence.
class OrgGraphTaxonomyRefusalMcpTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @tenant = create(:tenant)
    @application = Mcp::Application.create!(name: "Test MCP Client", redirect_uri: "https://client.example/callback",
                                            scopes: "read write", confidential: false)
    @squad = SecureRandom.uuid_v7
    @payments = SecureRandom.uuid_v7
    @user = create(:user)
    ActsAsTenant.with_tenant(@tenant) do
      create(:tenant_user, tenant: @tenant, user: @user, role: :member, person: create(:person, tenant: @tenant))
      structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
      structure.define_taxonomy([ { level_id: @squad, name: "Squad" } ], effective_on: Date.current)
      structure.create_unit(@payments, "Payments", level_id: @squad, effective_on: Date.current)
    end
    sign_in @user
  end

  should "refuse a member with no rights each taxonomy write on approval, with the command's sentence and no type's name" do
    calls = {
      "org_graph_add_level" => { name: "Guild" },
      "org_graph_remove_level" => { level_id: @squad },
      "org_graph_set_kind_parents" => { level_id: @squad, parent_ids: [], top: true }
    }

    calls.each do |tool, arguments|
      assert_refused ask_over_mcp(tool, arguments),
                     "Only a tenant admin or an Org Graph editor can change the organisation's structure"
      assert_refused ask_over_mcp(tool, arguments.merge(structure_unit_id: @payments)),
                     "You can change Payments's structure if you own Payments or a unit above it, " \
                     "report to someone who does, or are an Org Graph editor"
    end
    assert_equal %w[Squad], ActsAsTenant.with_tenant(@tenant) { OrgTaxonomyLevel.top_structure.pluck(:name) }
    assert_empty ActsAsTenant.with_tenant(@tenant) { OrgTaxonomyLevel.in_structure(@payments).to_a }
  end

  private

  def ask_over_mcp(name, arguments)
    token = Mcp::AccessToken.create!(application: @application, resource_owner_id: @user.id, tenant_id: @tenant.id,
                                     scopes: "read write", expires_in: 3600)
    post mcp_server_path,
         params: { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name:, arguments: } }.to_json,
         headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{token.token}" }
    assert_response :success
    Mcp::PendingApproval.find(JSON.parse(response.body).dig("result", "meta", "approvalId"))
  end

  def assert_refused(approval, sentence)
    post approve_mcp_approval_path(approval)

    assert_redirected_to mcp_approval_path(approval)
    assert_equal sentence, flash[:alert]
    assert_no_match(/Squad/, flash[:alert])
    assert_not_equal "approved", approval.reload.status
  end
end
