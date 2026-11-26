# frozen_string_literal: true

require "test_helper"
require_relative "../support/placement_suggestion_fixture"

# Once a person is forgotten, nobody accepts or dismisses a suggestion about
# their feedback, on the hub or through MCP, and nothing reaches their stream
# ([#586](https://github.com/espaliahq/espalia/issues/586)).
class ForgottenSuggestionDecisionsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include PlacementSuggestionFixture

  REFUSAL = "this person has been forgotten"

  setup do
    build_placement_fixture
    @item = record_peer_feedback
    with_fake_suggestion_model(proposals: [ proposal(@ownership) ]) { Evidence::SuggestPlacementsJob.perform_now(@item.id) }
    ActsAsTenant.with_tenant(@tenant) do
      @suggestion = EvidencePlacementSuggestion.find_by!(evidence_id: @item.id)
      @alex.update_columns(forgotten_at: Time.current, name: Person::FORMER_MEMBER, email: nil)
    end
  end

  def stream_events = Rails.configuration.event_store.read
    .stream(EventStreamNaming.person_development_stream(@alex.id, @framework_id, tenant: @tenant)).count

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

  should "refuse accept and dismiss on the hub, storing nothing" do
    sign_in @morgan_user

    assert_no_difference -> { stream_events } do
      stream_post accept_evidence_placement_suggestion_path(@suggestion)
      assert_response :unprocessable_content
      assert_includes response.body, REFUSAL

      stream_post dismiss_evidence_placement_suggestion_path(@suggestion), params: { reason: "Not about this" }
      assert_response :unprocessable_content
      assert_includes response.body, REFUSAL
    end
    ActsAsTenant.with_tenant(@tenant) { assert_equal "pending", @suggestion.reload.status }
  end

  should "refuse both MCP tools as invalid params, storing nothing" do
    assert_no_difference -> { stream_events } do
      [ [ "assessments_accept_evidence_suggestion", {} ],
        [ "assessments_dismiss_evidence_suggestion", { reason: "Not about this" } ] ].each do |tool, extra|
        error = call_tool(tool, { suggestion_id: @suggestion.id, **extra })["error"]
        assert_equal(-32602, error["code"], tool)
        assert_includes error["message"], REFUSAL, tool
      end
    end
  end
end
