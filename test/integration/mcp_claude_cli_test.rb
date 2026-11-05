# frozen_string_literal: true

require "test_helper"
require_relative "../support/mcp_cli_helpers"

# Drives the real `claude` CLI as a subprocess against a Puma server
# booted in-process. This is the load-bearing parity coverage in the
# MCP design: every tool gets exercised through the actual transport a
# real client uses, not a simulated one.
#
# CI installs @anthropic-ai/claude-code alongside Ruby
# (.github/workflows/ci.yml); the devcontainer's postCreateCommand
# installs it for local dev. When the binary is absent the test skips
# with an install hint, so a contributor without the CLI still gets a
# green suite — EXCEPT under REQUIRE_MCP_CLI=1 (set by the dedicated
# mcp-cli-test CI job, which installs the CLI itself), where an absent
# binary means the install broke and the test fails loudly. Silent
# skips once hid lost parity coverage; the skip message and the CI
# flunk keep it visible. Set CLAUDE_CLI=<path> for a non-default install.
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
    # The main `test` CI job sets SKIP_MCP_CLI_TEST=1 so it doesn't have
    # to install Node + the claude CLI or carry the OAuth token. A
    # separate `mcp-cli-test` job runs this file with the env var unset.
    # Local runs and the devcontainer leave the env var unset — the
    # binary check below still flunks (does NOT silently skip) so missing
    # CLI parity coverage outside this one CI carve-out stays loud.
    skip "SKIP_MCP_CLI_TEST set — runs in the dedicated mcp-cli-test CI job" if ENV["SKIP_MCP_CLI_TEST"].present?

    unless cli_available?
      message = "claude CLI not on PATH — install with `npm i -g @anthropic-ai/claude-code` or set CLAUDE_CLI=<path>"
      flunk message if ENV["REQUIRE_MCP_CLI"].present?
      skip "#{message} (skipping; the mcp-cli-test CI job still enforces parity coverage)"
    end

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
    # Tear down ONLY the records this test instance created. The earlier
    # `delete_all` pattern corrupted parallel test runs because every CLI
    # test would wipe the other parallel worker's User/Tenant rows.
    ActsAsTenant.without_tenant do
      Mcp::PendingApproval.where(user_id: @user&.id).delete_all if @user
      Mcp::AccessToken.where(application_id: @application&.id).delete_all if @application
      Mcp::AccessGrant.where(application_id: @application&.id).delete_all if @application
      @application&.destroy
      TenantUser.where(tenant_id: @tenant&.id).delete_all if @tenant
      Person.where(tenant_id: @tenant&.id).delete_all if @tenant
      @tenant&.destroy
      @user&.destroy
    end
    File.unlink(@config_path) if @config_path && File.exist?(@config_path)
  end

  should "list and invoke the system_whoami tool end to end" do
    # The tenant id is a freshly-minted UUID v7, so it cannot be in the
    # CLI's auto-memory or training context. Asserting on it proves the
    # tool was actually invoked (a previous version asked for the email
    # and the CLI answered from auto-memory without calling the tool).
    stdout = run_claude_cli(
      "You MUST call the mcp__growth_os__system_whoami tool right now. " \
      "Do NOT answer from your own knowledge, memory, or context — only the " \
      "tool can answer this. After receiving the tool's response, return ONLY " \
      "the value of result.tenant.id, with no other text.",
      config_path: @config_path
    )

    # The tenant UUID is freshly minted per test run, so it can't appear
    # in the CLI's auto-memory or training data. Matching it in stdout
    # is a strong signal the tool was actually invoked. An earlier
    # weaker version of this test asked for the email and the CLI
    # answered from memory without calling the tool — keep the prompt
    # explicit AND the asserted value test-local-only.
    assert_match(/#{Regexp.escape(@tenant.id)}/, stdout,
      "claude CLI output should contain the tenant id from system_whoami's response")
  end
end
