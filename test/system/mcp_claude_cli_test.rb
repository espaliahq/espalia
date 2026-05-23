# frozen_string_literal: true

require "test_helper"
require_relative "../support/mcp_cli_helpers"

# Drives the real `claude` CLI as a subprocess against a Puma server
# booted in-process. This is the load-bearing parity coverage in the
# MCP design: every tool gets exercised through the actual transport a
# real client uses, not a simulated one.
#
# In CI the @anthropic-ai/claude-code package is expected to be installed
# alongside Ruby; locally these tests skip cleanly when the binary isn't
# on PATH so green local runs remain achievable. Set CLAUDE_CLI=<path>
# to point at a non-default install.
#
# Per-test workflow:
#   1. Mint a Doorkeeper access token directly (the OAuth UI is covered
#      separately by OauthPkceFlowTest).
#   2. Write a per-test .mcp.json config pointing at the test server +
#      bearer token.
#   3. `claude --print --mcp-config <file> --allowed-tools mcp__growth_os__*
#      <prompt>` and read stdout.
#   4. Assert stdout AND any DB-side effect.
#
# Note: this test class disables transactional fixtures so the Puma
# thread can see uncommitted data — DB rows created in setup are visible
# to the CLI's HTTP request. Cleanup is manual in teardown.
class McpClaudeCliTest < ActiveSupport::TestCase
  include McpCliHelpers

  self.use_transactional_tests = false

  setup do
    skip "claude CLI not on PATH (set CLAUDE_CLI=<path> or `npm i -g @anthropic-ai/claude-code`)" unless cli_available?

    @user = create(:user, password: "password123")
    @tenant = create(:tenant, name: "Workspace A")
    ActsAsTenant.with_tenant(@tenant) do
      @person = create(:person, tenant: @tenant, email: @user.email, name: "Alice")
      create(:tenant_user, tenant: @tenant, user: @user, person: @person, role: :member)
    end

    @application = Mcp::Application.create!(
      name: "Claude Test", redirect_uri: "https://x/cb",
      scopes: "read write", confidential: false
    )
    @token = Mcp::AccessToken.create!(
      application: @application, resource_owner_id: @user.id,
      tenant_id: @tenant.id, scopes: "read write", expires_in: 3600
    )

    @base_url = boot_test_server
    @config_path = write_mcp_config(base_url: @base_url, token: @token.token)
  end

  teardown do
    # Manual cleanup — no transactional fixtures here, so we tear down
    # what setup produced (and any approval rows the CLI may have created).
    Mcp::PendingApproval.delete_all
    Mcp::AccessToken.delete_all
    Mcp::AccessGrant.delete_all
    Mcp::Application.delete_all
    TenantUser.delete_all
    ActsAsTenant.with_tenant(@tenant) { Person.delete_all } if @tenant
    Tenant.delete_all
    User.delete_all
    File.unlink(@config_path) if @config_path && File.exist?(@config_path)
  end

  should "list and invoke the system_whoami tool end to end" do
    stdout = run_claude_cli(
      "Use the system_whoami tool and report back the user's email exactly as it appears.",
      config_path: @config_path
    )

    assert_match(/#{Regexp.escape(@user.email)}/, stdout,
      "claude CLI output should mention the user's email after calling system_whoami")
  end
end
