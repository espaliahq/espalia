# frozen_string_literal: true

require "test_helper"
require "digest"
require "base64"

# Two connections at once: the token endpoint on this one, replace_credentials! on another,
# so each must see the other's committed rows.
class McpTokenCredentialsRaceTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  self.use_transactional_tests = false

  CODE_VERIFIER = "abc123def456ghi789jkl012mno345pqr678stu901vwx234yz"
  CODE_CHALLENGE = Base64.urlsafe_encode64(Digest::SHA256.digest(CODE_VERIFIER), padding: false).freeze

  setup do
    @tenant = create(:tenant)
    @user = create(:user)
    @membership = create(:tenant_user, tenant: @tenant, user: @user, role: :member)
    @application = Mcp::Application.create!(name: "Race client", redirect_uri: "https://client.example/callback",
                                            scopes: "read write", confidential: false)
    sign_in @user
  end

  teardown do
    Mcp::AccessToken.where(resource_owner_id: @user.id).delete_all
    Mcp::AccessGrant.where(resource_owner_id: @user.id).delete_all
    @application.delete
    TenantUser.unscoped.where(tenant_id: @tenant.id).delete_all
    Person.unscoped.where(tenant_id: @tenant.id).delete_all
    linked = Tenant.sanitize_sql_array([ "stream LIKE ?", "tenant-#{@tenant.id}/%" ])
    event_ids = Tenant.connection.select_values("SELECT event_id FROM event_store_events_in_streams WHERE #{linked}")
    Tenant.connection.execute("DELETE FROM event_store_events_in_streams WHERE #{linked}")
    Tenant.connection.execute(Tenant.sanitize_sql_array([ "DELETE FROM event_store_events WHERE event_id IN (?)", event_ids ])) if event_ids.any?
    @user.delete
    @tenant.delete
  end

  should "refuse a refresh whose token is revoked after Doorkeeper checked it, leaving no live token" do
    refresh_token = exchange_code["refresh_token"]

    before_token_insert(-> { finished(on_another_connection { User.find(@user.id).replace_credentials! }) }) do
      post oauth_token_path, params: { grant_type: "refresh_token", client_id: @application.uid, refresh_token: }
    end

    assert_response :bad_request
    assert_equal "invalid_grant", JSON.parse(response.body)["error"]
    assert_empty live_tokens
  end

  should "let a code exchange holding its grant finish while credentials are replaced, then revoke its token" do
    @user.update_columns(provider: "google_oauth2", uid: "race-uid", reset_password_token: "race-token")
    code = authorization_code
    replacing = nil

    before_token_insert(-> { replacing = on_another_connection { User.find(@user.id).replace_credentials! }.tap { wait_until_blocked(it) } }) do
      post oauth_token_path, params: token_params(code)
    end

    assert_response :success
    assert_nil finished(replacing).value
    assert_empty live_tokens
  end

  private

  def authorization_code
    post oauth_authorization_path, params: {
      client_id: @application.uid, redirect_uri: @application.redirect_uri, response_type: "code", scope: "read write",
      state: "xyz", code_challenge: CODE_CHALLENGE, code_challenge_method: "S256", tenant_id: @tenant.id
    }
    response.location[/code=([^&]+)/, 1]
  end

  def token_params(code)
    { grant_type: "authorization_code", client_id: @application.uid, redirect_uri: @application.redirect_uri,
      code:, code_verifier: CODE_VERIFIER }
  end

  def exchange_code
    post oauth_token_path, params: token_params(authorization_code)
    assert_response :success
    JSON.parse(response.body)
  end

  def live_tokens = Mcp::AccessToken.where(resource_owner_id: @user.id, revoked_at: nil).to_a

  # Runs once, inside the insert's transaction, before the model's own callbacks.
  def before_token_insert(action)
    fired = false
    hook = ->(_token) { action.call unless fired; fired = true }
    Mcp::AccessToken.set_callback(:create, :before, hook, prepend: true)
    yield
  ensure
    Mcp::AccessToken.skip_callback(:create, :before, hook)
  end

  def on_another_connection(&work)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        Thread.current[:pid] = connection.raw_connection.backend_pid
        work.call
        nil
      end
    end.tap { |thread| Thread.pass until thread[:pid] || !thread.alive? }
  end

  def finished(thread)
    thread.join(10) || flunk("replace_credentials! still waiting after 10 seconds")
  end

  # Uncached, as the request's query cache would replay the first answer.
  def wait_until_blocked(thread)
    waiting = ActiveRecord::Base.sanitize_sql_array([ "SELECT EXISTS (SELECT 1 FROM pg_locks WHERE pid = ? AND NOT granted)", thread[:pid] ])
    ActiveRecord::Base.uncached do
      100.times do
        return if ActiveRecord::Base.connection.select_value(waiting)

        sleep 0.05
      end
    end
    flunk "replace_credentials! never waited on a lock (thread #{thread.status.inspect})"
  end
end
