# frozen_string_literal: true

require "test_helper"
require "digest"
require "base64"

# Two connections at once: a consent, MCP call or token request on this one,
# replace_credentials! on another, so each must see the other's committed rows.
class McpTokenCredentialsRaceTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include McpRequestCredentialsHelpers

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
    ActsAsTenant.without_tenant { Mcp::PendingApproval.where(user_id: @user.id).delete_all }
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


  should "send a consent to sign in again, storing no grant, when credentials are replaced before it is stored" do
    before_insert(Mcp::AccessGrant, -> { finished(on_another_connection { User.find(@user.id).replace_credentials! }) }) do
      authorization_code
    end

    assert_redirected_to new_user_session_url
    assert_empty Mcp::AccessGrant.where(resource_owner_id: @user.id)
    assert_equal({ "client_id" => @application.uid, "tenant_id" => @tenant.id.to_s, "state" => "xyz" },
                 Rack::Utils.parse_query(URI(session[:user_return_to]).query).slice("client_id", "tenant_id", "state"))
    get root_path
    assert_redirected_to new_user_session_path
  end

  should "revoke the grant of a consent that held the account while credentials were replaced" do
    replacing = nil

    after_insert(Mcp::AccessGrant, -> { replacing = on_another_connection { User.find(@user.id).replace_credentials! }.tap { wait_until_blocked(it) } }) do
      authorization_code
    end

    assert response.location.start_with?(@application.redirect_uri)
    assert_nil finished(replacing).value
    assert_equal 1, Mcp::AccessGrant.where(resource_owner_id: @user.id).count
    assert_empty Mcp::AccessGrant.where(resource_owner_id: @user.id, revoked_at: nil)
  end

  should "let a consent finish while a code exchange holds its grant" do
    code = authorization_code
    consenting = nil

    before_insert(Mcp::AccessToken, -> { consenting = finished(on_another_connection { store_a_grant(User.find(@user.id)) }) }) do
      post oauth_token_path, params: token_params(code)
    end

    assert_response :success
    assert_nil consenting.value
    assert_equal 2, Mcp::AccessGrant.where(resource_owner_id: @user.id).count
  end

  should "answer an MCP call like a revoked token, storing no approval, when credentials are replaced before it is stored" do
    token = Mcp::AccessToken.create!(application: @application, resource_owner_id: @user.id, tenant_id: @tenant.id,
                                     scopes: "read write", expires_in: 3600)

    with_whoami_awaiting_approval do
      before_insert(Mcp::PendingApproval, -> { finished(on_another_connection { User.find(@user.id).replace_credentials! }) }) do
        call_whoami(token)
      end
      refused = [ response.status, response.headers["WWW-Authenticate"], response.body ]

      call_whoami(token)
      assert_equal [ 401, response.headers["WWW-Authenticate"], response.body ], refused
    end
    assert_empty ActsAsTenant.without_tenant { Mcp::PendingApproval.where(user_id: @user.id) }
  end

  should "answer an MCP call like an unknown token, storing no approval, when its token is deleted before it is stored" do
    token = Mcp::AccessToken.create!(application: @application, resource_owner_id: @user.id, tenant_id: @tenant.id,
                                     scopes: "read write", expires_in: 3600)

    with_whoami_awaiting_approval do
      before_insert(Mcp::PendingApproval, -> { finished(on_another_connection { Mcp::AccessToken.where(id: token.id).delete_all }) }) do
        call_whoami(token)
      end
    end

    assert_response :unauthorized
    assert_empty ActsAsTenant.without_tenant { Mcp::PendingApproval.where(user_id: @user.id) }
  end

  should "answer an MCP call like a revoked token, storing no approval, when its token expires before it is stored" do
    token = live_token

    with_whoami_awaiting_approval do
      before_insert(Mcp::PendingApproval, -> { Mcp::AccessToken.where(id: token.id).update_all(created_at: 2.hours.ago) }) do
        call_whoami(token)
      end
    end

    assert_response :unauthorized
    assert_empty ActsAsTenant.without_tenant { Mcp::PendingApproval.where(user_id: @user.id) }
  end

  should "answer an MCP call like a revoked token, storing no approval, when its token is revoked with a stamp ahead of this clock" do
    token = live_token

    with_whoami_awaiting_approval do
      before_insert(Mcp::PendingApproval, -> { Mcp::AccessToken.where(id: token.id).update_all(revoked_at: 1.second.from_now) }) do
        call_whoami(token)
      end
    end

    assert_response :unauthorized
    assert_empty ActsAsTenant.without_tenant { Mcp::PendingApproval.where(user_id: @user.id) }
  end

  should "store the approval of an MCP call whose token is still live" do
    with_whoami_awaiting_approval { call_whoami(live_token) }

    assert_response :success
    assert_equal 1, ActsAsTenant.without_tenant { Mcp::PendingApproval.where(user_id: @user.id).count }
  end

  private

  def live_token
    Mcp::AccessToken.create!(application: @application, resource_owner_id: @user.id, tenant_id: @tenant.id,
                             scopes: "read write", expires_in: 3600)
  end

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

  def before_token_insert(action, &) = before_insert(Mcp::AccessToken, action, &)

  # Runs once, inside the insert's transaction, before the model's own callbacks.
  def before_insert(model, action, &) = once_on_insert(model, :before, action, prepend: true, &)

  # Runs once, inside the insert's transaction, after the row is written.
  def after_insert(model, action, &) = once_on_insert(model, :after, action, &)

  def once_on_insert(model, kind, action, **options)
    fired = false
    hook = ->(_record) { action.call unless fired; fired = true }
    model.set_callback(:create, kind, hook, **options)
    yield
  ensure
    model.skip_callback(:create, kind, hook)
  end

  def store_a_grant(user)
    as_consent_by(user) do
      Mcp::AccessGrant.create!(application: @application, resource_owner_id: user.id, tenant_id: @tenant.id, scopes: "read",
                               expires_in: 600, redirect_uri: @application.redirect_uri, code_challenge: CODE_CHALLENGE,
                               code_challenge_method: "S256")
    end
  end

  def call_whoami(token)
    post mcp_server_path, params: { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "system_whoami", arguments: {} } }.to_json,
                          headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{token.token}" }
  end

  def with_whoami_awaiting_approval
    whoami = Operations::System::Whoami
    category, approval = whoami.instance_variable_get(:@category), whoami.instance_variable_get(:@approval)
    whoami.instance_variable_set(:@category, :write)
    whoami.instance_variable_set(:@approval, :in_app)
    yield
  ensure
    whoami.instance_variable_set(:@category, category)
    whoami.instance_variable_set(:@approval, approval)
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
