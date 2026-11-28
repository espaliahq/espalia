# frozen_string_literal: true

require "test_helper"

class PasswordResetMcpAccessTest < ActionDispatch::IntegrationTest
  include McpRequestCredentialsHelpers

  setup do
    @tenant = create(:tenant)
    @account = create(:user, email: "colleague@example.com", password: "old-password-1", password_confirmation: "old-password-1",
                             provider: "google_oauth2", uid: "google-uid-1")
    ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, user: @account) }
    @client = Mcp::Application.create!(name: "Client", redirect_uri: "https://client.example/cb", scopes: "read", confidential: false)
  end

  should "revoke the account's MCP tokens, grants and calls awaiting approval, and keep its Google link" do
    token, grant, approval = mcp_credentials(@tenant)

    reset_password(@account.send_reset_password_instructions)

    assert @account.reload.valid_password?("new-password-1")
    assert token.reload.revoked?
    assert grant.reload.revoked?
    assert approval.reload.rejected?
    assert_equal %w[google_oauth2 google-uid-1], [ @account.provider, @account.uid ]
  end

  should "revoke a token and grant whose revocation is stamped ahead of this clock" do
    token, grant, = mcp_credentials(@tenant)
    [ token, grant ].each { it.update_columns(revoked_at: 1.hour.from_now) }

    reset_password(@account.send_reset_password_instructions)

    assert(token.reload.revoked_at <= Time.current)
    assert(grant.reload.revoked_at <= Time.current)
  end

  should "revoke nothing when the reset fails" do
    token, grant, approval = mcp_credentials(@tenant)

    reset_password(@account.send_reset_password_instructions, confirmation: "something-else")

    assert_response :unprocessable_content
    assert @account.reload.valid_password?("old-password-1")
    assert_not token.reload.revoked?
    assert_not grant.reload.revoked?
    assert approval.reload.pending?
  end

  should "revoke nothing when a reset fails inside a caller's transaction" do
    token, grant, approval = mcp_credentials(@tenant)

    User.transaction { assert_not @account.reset_password("new-password-1", "something-else") }

    assert_not token.reload.revoked?
    assert_not grant.reload.revoked?
    assert approval.reload.pending?
  end

  should "revoke nothing for an unknown reset token" do
    token, = mcp_credentials(@tenant)

    reset_password("not-a-token")

    assert_response :unprocessable_content
    assert_not token.reload.revoked?
  end

  should "revoke after taking the credentials lock" do
    reset_token = @account.send_reset_password_instructions
    queries = []
    record = ->(*, payload) { queries << payload[:sql] }

    ActiveSupport::Notifications.subscribed(record, "sql.active_record") { reset_password(reset_token) }

    lock = queries.index { it.include?("FOR NO KEY UPDATE") }
    revoke = queries.index { it.start_with?('UPDATE "oauth_access_grants"') }
    assert lock && revoke && lock < revoke, "the reset should lock the account before revoking its grants"
  end

  context "ending an account's MCP access" do
    should "refuse to run outside a transaction, revoking nothing" do
      token, = mcp_credentials(@tenant)

      assert_raises(User::NoTransaction) { @account.end_mcp_access! }
      assert_not token.reload.revoked?
    end

    should "lock the account itself with a fresh query before revoking" do
      @account.email = "unsaved@example.com"
      queries = []
      record = ->(*, payload) { queries << payload[:sql] }

      ActiveSupport::Notifications.subscribed(record, "sql.active_record") do
        @account.transaction { @account.end_mcp_access! }
      end

      lock = queries.index { it.match?(/SELECT "users"."id" FROM "users" WHERE "users"."id" = .* FOR NO KEY UPDATE/) }
      revoke = queries.index { it.start_with?('UPDATE "oauth_access_grants"') }
      assert lock && revoke && lock < revoke, "it should lock the account row before revoking"
    end
  end

  should "lock and revoke for a reset on a record loaded without a reset token" do
    token, = mcp_credentials(@tenant)

    assert @account.reset_password("new-password-1", "new-password-1")

    assert @account.reload.valid_password?("new-password-1")
    assert token.reload.revoked?
  end

  private

  def reset_password(token, confirmation: "new-password-1")
    put "/users/password", params: { user: { reset_password_token: token, password: "new-password-1", password_confirmation: confirmation } }
  end

  def mcp_credentials(tenant)
    token = Mcp::AccessToken.create!(application: @client, resource_owner_id: @account.id, tenant_id: tenant.id, scopes: "read", expires_in: 3600)
    grant = as_consent_by(@account) do
      Mcp::AccessGrant.create!(application: @client, resource_owner_id: @account.id, tenant_id: tenant.id, scopes: "read",
                               expires_in: 600, redirect_uri: @client.redirect_uri)
    end
    approval = as_mcp_call_with(token) do
      Mcp::PendingApproval.create!(user: @account, tenant:, client_application: @client,
                                   operation_class: "Operations::System::Whoami", arguments: {}, expires_at: 1.hour.from_now)
    end
    [ token, grant, approval ]
  end
end
