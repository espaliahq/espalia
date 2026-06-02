# frozen_string_literal: true

require "test_helper"

class Settings::ConnectedClientsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = create(:user, password: "password123")
    @tenant = create(:tenant, name: "Workspace A")
    ActsAsTenant.with_tenant(@tenant) do
      create(:tenant_user, tenant: @tenant, user: @user, role: :member)
    end

    @other_user = create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, user: @other_user, role: :member) }

    @application = Mcp::Application.create!(
      name: "Test MCP Client",
      redirect_uri: "https://client.example/callback",
      scopes: "read write",
      confidential: false
    )

    @my_token = Mcp::AccessToken.create!(
      application: @application, resource_owner_id: @user.id,
      tenant_id: @tenant.id, scopes: "read write", expires_in: 3600
    )

    @other_token = Mcp::AccessToken.create!(
      application: @application, resource_owner_id: @other_user.id,
      tenant_id: @tenant.id, scopes: "read", expires_in: 3600
    )
  end

  context "GET /settings/connected_clients" do
    should "list the current user's non-revoked tokens" do
      sign_in @user
      get settings_connected_clients_path

      assert_response :success
      assert_match "Test MCP Client", response.body
      assert_match "read write", response.body
    end

    should "omit other users' tokens" do
      sign_in @user
      get settings_connected_clients_path

      assert_response :success
      # The page renders revoke links keyed by token id; assert the other
      # user's id never appears in any of them.
      doc_token_ids = response.body.scan(/settings\/connected_clients\/([0-9a-f-]+)/).flatten
      refute_includes doc_token_ids, @other_token.id
    end

    should "render an empty state when there are no tokens" do
      @my_token.update!(revoked_at: Time.current)
      sign_in @user
      get settings_connected_clients_path

      assert_response :success
      assert_match(/No MCP clients connected/, response.body)
    end

    should "render connect instructions for each supported client" do
      sign_in @user
      get settings_connected_clients_path

      assert_response :success
      assert_match "Connect an assistant", response.body
      assert_match "MCP server URL", response.body
      assert_match "Claude Code", response.body
      assert_match "Claude.ai &amp; Claude Desktop", response.body
      assert_match "ChatGPT", response.body
      assert_match "Codex", response.body
    end

    should "render the MCP endpoint URL built from the request host" do
      sign_in @user
      get settings_connected_clients_path

      assert_response :success
      # No OAUTH_ISSUER configured in test → falls back to request base URL.
      assert_match "#{request.base_url}/mcp", response.body
      assert_match "claude mcp add --transport http growthos", response.body
    end
  end

  context "DELETE /settings/connected_clients/:id" do
    should "revoke the user's own token" do
      sign_in @user
      delete settings_connected_client_path(@my_token)

      assert_redirected_to settings_connected_clients_path
      @my_token.reload
      assert @my_token.revoked_at.present?, "token should be revoked"
    end

    should "refuse to revoke another user's token" do
      sign_in @user
      delete settings_connected_client_path(@other_token)

      assert_redirected_to settings_connected_clients_path
      assert_match(/not found/i, flash[:alert])
      @other_token.reload
      assert_nil @other_token.revoked_at
    end
  end
end
