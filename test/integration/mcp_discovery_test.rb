# frozen_string_literal: true

require "test_helper"

# Covers the OAuth discovery + DCR surface that lets an MCP client hit
# /mcp cold (with no client_id in config) and walk through to a usable
# token: 401 → resource metadata → auth server metadata → register →
# /oauth/authorize. Without these endpoints, the CLI emits "no route
# matches" against the well-known paths.
class McpDiscoveryTest < ActionDispatch::IntegrationTest
  context "POST /mcp without a bearer token" do
    should "return 401 with a WWW-Authenticate header pointing at the resource metadata" do
      post mcp_server_path,
        params: "{}",
        headers: { "Content-Type" => "application/json" }

      assert_response :unauthorized
      header = response.headers["WWW-Authenticate"]
      assert header.present?, "WWW-Authenticate header missing"
      assert_match(/\ABearer\b/, header)
      assert_match(
        %r{resource_metadata="https?://[^/]+/.well-known/oauth-protected-resource"},
        header
      )
    end
  end

  context "GET /.well-known/oauth-protected-resource" do
    should "return the protected-resource metadata document" do
      get "/.well-known/oauth-protected-resource"

      assert_response :success
      body = JSON.parse(response.body)
      assert body["resource"].present?
      assert_equal [ body["resource"] ], body["authorization_servers"]
      assert_equal %w[read write], body["scopes_supported"]
      assert_equal [ "header" ], body["bearer_methods_supported"]
    end
  end

  context "GET /.well-known/oauth-authorization-server" do
    should "return the authorization-server metadata document" do
      get "/.well-known/oauth-authorization-server"

      assert_response :success
      body = JSON.parse(response.body)
      assert body["issuer"].present?
      assert_match %r{/oauth/authorize\z}, body["authorization_endpoint"]
      assert_match %r{/oauth/token\z},     body["token_endpoint"]
      assert_match %r{/oauth/register\z},  body["registration_endpoint"]
      assert_equal [ "code" ],                body["response_types_supported"]
      assert_equal [ "authorization_code", "refresh_token" ], body["grant_types_supported"]
      assert_equal [ "S256" ],                body["code_challenge_methods_supported"]
      assert_equal %w[read write],            body["scopes_supported"]
      assert_equal [ "none" ],                body["token_endpoint_auth_methods_supported"]
    end

    should "canonicalise a configured issuer with a trailing slash" do
      original = Rails.application.config.x.oauth_issuer
      Rails.application.config.x.oauth_issuer = "https://growth.example.com/"
      get "/.well-known/oauth-authorization-server"

      assert_response :success
      body = JSON.parse(response.body)
      assert_equal "https://growth.example.com", body["issuer"]
      assert_equal "https://growth.example.com/oauth/authorize", body["authorization_endpoint"]
    ensure
      Rails.application.config.x.oauth_issuer = original
    end
  end

  context "POST /oauth/register (Dynamic Client Registration)" do
    should "create a public Mcp::Application and return the client_id" do
      assert_difference -> { Mcp::Application.count }, 1 do
        post "/oauth/register",
          params: { client_name: "DCR Test", redirect_uris: [ "http://localhost:54321/cb" ] }.to_json,
          headers: { "Content-Type" => "application/json" }
      end

      assert_response :created
      body = JSON.parse(response.body)
      assert body["client_id"].present?
      assert_equal "DCR Test",                body["client_name"]
      assert_equal [ "http://localhost:54321/cb" ], body["redirect_uris"]
      assert_equal [ "authorization_code", "refresh_token" ], body["grant_types"]
      assert_equal "none",                    body["token_endpoint_auth_method"]
      assert_equal "read",                    body["scope"]

      app = Mcp::Application.find_by(uid: body["client_id"])
      assert app
      refute app.confidential?, "DCR-registered clients must be public (no secret)"
      assert app.dynamically_registered_at.present?,
        "must mark DCR registrations so Mcp::PruneStaleClientsJob can clean them up"
    end

    should "reject a registration with no redirect_uris" do
      assert_no_difference -> { Mcp::Application.count } do
        post "/oauth/register",
          params: { client_name: "Bad" }.to_json,
          headers: { "Content-Type" => "application/json" }
      end

      assert_response :bad_request
      body = JSON.parse(response.body)
      assert_equal "invalid_redirect_uri", body["error"]
    end

    should "downgrade an unknown scope to the safe default" do
      post "/oauth/register",
        params: {
          client_name: "ScopeTest",
          redirect_uris: [ "http://localhost:54321/cb" ],
          scope: "delete-everything"
        }.to_json,
        headers: { "Content-Type" => "application/json" }

      assert_response :created
      assert_equal "read", JSON.parse(response.body)["scope"]
    end
  end
end
