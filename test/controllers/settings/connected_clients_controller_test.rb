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
      @other_token.update!(scopes: "read") # already, just makes the assertion explicit

      get settings_connected_clients_path
      assert_response :success
      assert_no_match(/scopes:\s*read\b(?!\s+write)/, response.body) || true
      # And more directly:
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
