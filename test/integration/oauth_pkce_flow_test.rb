# frozen_string_literal: true

require "test_helper"
require "digest"
require "base64"

# Full PKCE authorisation-code flow against the Doorkeeper provider, with
# the tenant-picker consent screen in the middle. Asserts that:
#   - the consent screen lists the user's tenants and rejects foreign ones
#   - `tenant_id` survives the round trip from consent → grant → token
#   - PKCE is enforced (no token without code_verifier)
#   - a refresh token is issued and renews while preserving the tenant binding
class OauthPkceFlowTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  CODE_VERIFIER = "abc123def456ghi789jkl012mno345pqr678stu901vwx234yz"
  CODE_CHALLENGE = Base64.urlsafe_encode64(
    Digest::SHA256.digest(CODE_VERIFIER), padding: false
  ).freeze

  setup do
    @user = create(:user, password: "password123")
    @tenant_a = create(:tenant, name: "Workspace A")
    @tenant_b = create(:tenant, name: "Workspace B")
    @foreign_tenant = create(:tenant, name: "Not Mine")

    create(:tenant_user, tenant: @tenant_a, user: @user, role: :member)
    create(:tenant_user, tenant: @tenant_b, user: @user, role: :member)
    # Deliberately NOT a member of @foreign_tenant.

    @application = Mcp::Application.create!(
      name: "Test MCP Client",
      redirect_uri: "https://client.example/callback",
      scopes: "read write",
      confidential: false
    )
  end

  # Common OAuth params for /oauth/authorize.
  def auth_params(extra = {})
    {
      client_id: @application.uid,
      redirect_uri: @application.redirect_uri,
      response_type: "code",
      scope: "read write",
      state: "xyz",
      code_challenge: CODE_CHALLENGE,
      code_challenge_method: "S256"
    }.merge(extra)
  end

  context "GET /oauth/authorize" do
    should "redirect to sign-in when unauthenticated" do
      get oauth_authorization_path, params: auth_params
      assert_redirected_to new_user_session_path
    end

    should "return to the original authorize URL after signing in (deep link honoured)" do
      # Anonymous hit stashes the full authorize URL and bounces to sign-in.
      get oauth_authorization_path, params: auth_params
      assert_redirected_to new_user_session_path
      assert_includes session[:user_return_to], "/oauth/authorize?"
      assert_includes session[:user_return_to], "client_id=#{@application.uid}"

      # Signing in through the real form must land back on the authorize URL,
      # not the home page — otherwise the MCP OAuth flow dead-ends.
      post user_session_path, params: {
        user: { email: @user.email, password: "password123" }
      }

      assert_response :redirect
      assert_includes response.location, "/oauth/authorize"
      assert_includes response.location, "client_id=#{@application.uid}"
    end

    should "render the consent screen with a tenant picker for the signed-in user's tenants" do
      sign_in @user
      get oauth_authorization_path, params: auth_params

      assert_response :success
      assert_match "Test MCP Client", response.body
      assert_match "Workspace A", response.body
      assert_match "Workspace B", response.body
      assert_no_match(/Not Mine/, response.body)
      # Tenant picker is present and posts back to /oauth/authorize.
      assert_match(/name="tenant_id"/, response.body)
    end

    should "render through the app layout so the Tailwind stylesheet loads (not Doorkeeper's bare layout)" do
      sign_in @user
      get oauth_authorization_path, params: auth_params

      assert_response :success
      # The app layout links the compiled Tailwind stylesheet; the consent
      # screen's Phlex classes are unstyled without it (the "blank screen" bug).
      assert_match %r{<link[^>]+href="[^"]*tailwind[^"]*\.css}, response.body,
        "consent screen must render through layouts/application (Tailwind present)"
      # And NOT Doorkeeper's bare layout, whose only stylesheet is doorkeeper/application.
      assert_no_match %r{href="[^"]*doorkeeper/application[^"]*\.css}, response.body
    end
  end

  context "POST /oauth/authorize" do
    setup { sign_in @user }

    should "issue an AccessGrant bound to the chosen tenant and redirect with code" do
      assert_difference -> { Mcp::AccessGrant.count }, 1 do
        post oauth_authorization_path, params: auth_params(tenant_id: @tenant_a.id)
      end

      grant = Mcp::AccessGrant.last
      assert_equal @tenant_a.id, grant.tenant_id
      assert_equal @user.id.to_s, grant.resource_owner_id.to_s
      assert_equal @application.id, grant.application_id
      assert_equal CODE_CHALLENGE, grant.code_challenge
      assert_equal "S256", grant.code_challenge_method

      assert_response :redirect
      assert_match %r{\Ahttps://client\.example/callback\?}, response.location
      assert_match(/code=/, response.location)
      assert_match(/state=xyz/, response.location)
    end

    should "reject a tenant the user does not belong to without creating a grant" do
      assert_no_difference -> { Mcp::AccessGrant.count } do
        post oauth_authorization_path, params: auth_params(tenant_id: @foreign_tenant.id)
      end
      assert_response :unprocessable_content
      assert_match(/Select a workspace you belong to/, response.body)
    end

    should "reject a missing tenant_id without creating a grant" do
      assert_no_difference -> { Mcp::AccessGrant.count } do
        post oauth_authorization_path, params: auth_params(tenant_id: "")
      end
      assert_response :unprocessable_content
    end

    should "be rejected by Doorkeeper when code_challenge is absent (PKCE enforced)" do
      params = auth_params(tenant_id: @tenant_a.id)
      params.delete(:code_challenge)
      params.delete(:code_challenge_method)

      assert_no_difference -> { Mcp::AccessGrant.count } do
        post oauth_authorization_path, params: params
      end
      # Doorkeeper redirects back to redirect_uri with an error param when PKCE missing.
      assert_response :redirect
      assert_match(/error=invalid_request/, response.location)
    end
  end

  context "POST /oauth/token" do
    setup do
      sign_in @user
      post oauth_authorization_path, params: auth_params(tenant_id: @tenant_a.id)
      @grant = Mcp::AccessGrant.last
      @code  = response.location[/code=([^&]+)/, 1]
    end

    should "exchange the code for an access token that carries tenant_id" do
      assert_difference -> { Mcp::AccessToken.count }, 1 do
        post oauth_token_path, params: {
          grant_type: "authorization_code",
          client_id: @application.uid,
          redirect_uri: @application.redirect_uri,
          code: @code,
          code_verifier: CODE_VERIFIER
        }
      end

      assert_response :success
      body = JSON.parse(response.body)
      assert body["access_token"].present?
      assert body["refresh_token"].present?, "a refresh token is issued for silent renewal"

      token = Mcp::AccessToken.last
      assert_equal @tenant_a.id, token.tenant_id
      assert_equal @user.id.to_s, token.resource_owner_id.to_s
      assert_equal @application.id, token.application_id
    end

    should "renew via the refresh token, preserving the tenant binding without a browser round trip" do
      post oauth_token_path, params: {
        grant_type: "authorization_code",
        client_id: @application.uid,
        redirect_uri: @application.redirect_uri,
        code: @code,
        code_verifier: CODE_VERIFIER
      }
      refresh_token = JSON.parse(response.body)["refresh_token"]
      assert refresh_token.present?

      assert_difference -> { Mcp::AccessToken.count }, 1 do
        post oauth_token_path, params: {
          grant_type: "refresh_token",
          client_id: @application.uid,
          refresh_token: refresh_token
        }
      end

      assert_response :success
      body = JSON.parse(response.body)
      assert body["access_token"].present?

      renewed = Mcp::AccessToken.last
      assert_equal @tenant_a.id, renewed.tenant_id,
        "tenant_id custom attribute must carry through the refresh exchange"
      assert_equal @user.id.to_s, renewed.resource_owner_id.to_s
      assert_equal @application.id, renewed.application_id
    end

    should "reject the exchange without code_verifier (PKCE enforced)" do
      assert_no_difference -> { Mcp::AccessToken.count } do
        post oauth_token_path, params: {
          grant_type: "authorization_code",
          client_id: @application.uid,
          redirect_uri: @application.redirect_uri,
          code: @code
        }
      end
      assert_response :bad_request
    end
  end
end
