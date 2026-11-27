# frozen_string_literal: true

require "test_helper"
require_relative "../support/placement_suggestion_fixture"

# Forgetting the person who wrote the feedback leaves the suggestion about the
# assessee decidable, on the hub and through MCP
# ([#590](https://github.com/espaliahq/espalia/issues/590)).
class ForgottenAuthorSuggestionDecisionsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include PlacementSuggestionFixture

  setup do
    build_placement_fixture
    @item = record_peer_feedback
    with_fake_suggestion_model(proposals: [ proposal(@ownership), proposal(@collaboration) ]) do
      Evidence::SuggestPlacementsJob.perform_now(@item.id)
    end
    ActsAsTenant.with_tenant(@tenant) do
      @accepted, @dismissed = EvidencePlacementSuggestion.where(evidence_id: @item.id).order(:created_at).to_a
      @jordan.update_columns(forgotten_at: Time.current, name: Person::FORMER_MEMBER, email: nil)
    end
  end

  def stream_post(path, params: {})
    post path, params: params, headers: { "Accept" => "text/vnd.turbo-stream.html, text/html" }
  end

  def call_tool(name, arguments)
    application = Mcp::Application.create!(name: "Test MCP Client", redirect_uri: "https://client.example/callback",
                                           scopes: "read write", confidential: false)
    token = Mcp::AccessToken.create!(application: application, resource_owner_id: @morgan_user.id, tenant_id: @tenant.id,
                                     scopes: "read write", expires_in: 3600)
    post mcp_server_path, params: { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name:, arguments: } }.to_json,
                          headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{token.token}" }
    JSON.parse(response.body)
  end

  should "accept and dismiss on the hub" do
    sign_in @morgan_user

    stream_post accept_evidence_placement_suggestion_path(@accepted)
    assert_response :success
    stream_post dismiss_evidence_placement_suggestion_path(@dismissed), params: { reason: "Not about this" }
    assert_response :success

    ActsAsTenant.with_tenant(@tenant) do
      assert_equal "accepted", @accepted.reload.status
      assert_equal "dismissed", @dismissed.reload.status
    end
  end

  should "accept and dismiss through both MCP tools" do
    assert_nil call_tool("assessments_accept_evidence_suggestion", { suggestion_id: @accepted.id })["error"]
    assert_nil call_tool("assessments_dismiss_evidence_suggestion",
                         { suggestion_id: @dismissed.id, reason: "Not about this" })["error"]

    ActsAsTenant.with_tenant(@tenant) do
      assert_equal "accepted", @accepted.reload.status
      assert_equal "dismissed", @dismissed.reload.status
    end
  end
end
