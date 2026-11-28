# frozen_string_literal: true

require "test_helper"

class ProvisioningCredentialsTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    @person = ActsAsTenant.with_tenant(@tenant) { create(:person, tenant: @tenant, email: "colleague@example.com") }
    @account = create(:user, email: "colleague@example.com", password: "old-password-1", password_confirmation: "old-password-1")
  end

  context "an account no tenant holds" do
    should "lose its password and its session when provisioning adopts it" do
      sign_in_with_password
      get root_path
      assert_response :success

      assert_equal @account, @person.ensure_user!

      assert_not @account.reload.valid_password?("old-password-1")
      get root_path
      assert_redirected_to new_user_session_path
    end

    should "lose its remember-me cookie when provisioning adopts it" do
      sign_in_with_password(remember: true)
      drop_session_cookie
      get root_path
      assert_response :success, "the remember-me cookie alone should sign the account in before adoption"

      @person.ensure_user!

      drop_session_cookie
      get root_path
      assert_redirected_to new_user_session_path
    end

    should "be linked to the person only once its credentials are replaced" do
      @person.ensure_user!

      membership = ActsAsTenant.without_tenant { TenantUser.find_by!(user: @account) }
      assert_equal [ @tenant.id, @person.id ], [ membership.tenant_id, membership.person_id ]
      assert_not @account.reload.valid_password?("old-password-1")
    end

    should "lose its MCP tokens, grants and calls awaiting approval when provisioning adopts it" do
      token, grant, approval = mcp_credentials

      @person.ensure_user!

      assert token.reload.revoked?
      assert grant.reload.revoked?
      assert approval.reload.rejected?
    end

    should "be refused at the MCP endpoint with a token issued before adoption" do
      token, = mcp_credentials

      @person.ensure_user!

      call_mcp(token)
      assert_response :unauthorized

      call_mcp(Mcp::AccessToken.create!(application: token.application, resource_owner_id: @account.id,
                                        tenant_id: @tenant.id, scopes: "read", expires_in: 3600))
      assert_response :success, "a token issued after adoption should reach the endpoint"
    end

    should "send no email and enqueue no job when its credentials are replaced" do
      assert_no_emails do
        assert_no_enqueued_jobs { @account.replace_credentials! }
      end
    end

    should "lose its linked Google identity when provisioning adopts it" do
      @account.update!(provider: "google_oauth2", uid: "earlier-uid")
      assert_equal [ @account, nil ], User.from_google_omniauth(google_auth("renamed@example.com", uid: "earlier-uid"))

      @person.ensure_user!

      assert_equal [ nil, :no_matching_account ], User.from_google_omniauth(google_auth("renamed@example.com", uid: "earlier-uid"))
    end

    should "lose its password and tokens when a Google sign-in with a different identity claims its email" do
      @account.update!(provider: "google_oauth2", uid: "earlier-uid")
      token, = mcp_credentials

      signed_in, = User.from_google_omniauth(google_auth("colleague@example.com"))

      assert_equal @account, signed_in
      assert_not @account.reload.valid_password?("old-password-1")
      assert token.reload.revoked?
      assert_equal "google-uid-1", @account.uid
    end

    should "lose its password when a Google sign-in with its email claims it" do
      token, = mcp_credentials

      signed_in, = User.from_google_omniauth(google_auth("colleague@example.com"))

      assert_equal @account, signed_in
      assert_not @account.reload.valid_password?("old-password-1")
      assert token.reload.revoked?
    end
  end

  context "an account a tenant holds" do
    setup do
      other = create(:tenant)
      ActsAsTenant.with_tenant(other) { create(:tenant_user, tenant: other, user: @account) }
    end

    should "keep its password and tokens when provisioning adds a membership" do
      token, = mcp_credentials

      @person.ensure_user!

      assert @account.reload.valid_password?("old-password-1")
      assert_not token.reload.revoked?
    end

    should "keep its password when a Google sign-in with its email claims it" do
      User.from_google_omniauth(google_auth("colleague@example.com"))

      assert @account.reload.valid_password?("old-password-1")
    end
  end

  should "keep a global admin's password when provisioning adopts it" do
    @account.update!(global_admin: true, global_admin_source: "admin_task")

    @person.ensure_user!

    assert @account.reload.valid_password?("old-password-1")
  end

  private

  def sign_in_with_password(remember: false)
    post user_session_path, params: { user: { email: "colleague@example.com", password: "old-password-1", remember_me: remember ? "1" : "0" } }
  end

  def drop_session_cookie
    cookies.delete(Rails.application.config.session_options[:key])
  end

  def mcp_credentials
    app = Mcp::Application.create!(name: "Client", redirect_uri: "https://client.example/cb", scopes: "read", confidential: false)
    token = Mcp::AccessToken.create!(application: app, resource_owner_id: @account.id, tenant_id: @tenant.id, scopes: "read", expires_in: 3600)
    grant = Mcp::AccessGrant.create!(application: app, resource_owner_id: @account.id, tenant_id: @tenant.id, scopes: "read",
                                     expires_in: 600, redirect_uri: app.redirect_uri)
    approval = Mcp::PendingApproval.create!(user: @account, tenant: @tenant, client_application: app,
                                            operation_class: "Operations::System::Whoami", arguments: {}, expires_at: 1.hour.from_now)
    [ token, grant, approval ]
  end

  def call_mcp(token)
    post mcp_server_path, params: { jsonrpc: "2.0", id: 1, method: "initialize" }.to_json,
                          headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{token.token}" }
  end

  def google_auth(email, uid: "google-uid-1")
    OmniAuth::AuthHash.new(provider: "google_oauth2", uid:, info: { "email" => email, "email_verified" => true },
                           extra: { raw_info: { "email_verified" => true } })
  end
end
