# frozen_string_literal: true

require "capybara"
require "shellwords"
require "tempfile"
require "open3"

# Drives the real `claude` CLI as a subprocess against a Puma server
# booted inside the test process. Used by McpClaudeCliTest to validate
# the full chain — bearer auth → tools/list → tools/call → result —
# against the same MCP transport a real client would speak.
#
# `cli_available?` is a precondition check: the consuming test should
# `flunk` (not `skip`) when it returns false. CI installs the CLI in
# the test job and the devcontainer's postCreateCommand installs it
# for local dev, so absence is treated as a setup failure, not a
# legitimate run condition.
module McpCliHelpers
  CLAUDE_CLI = ENV["CLAUDE_CLI"] || "claude"
  CLI_TIMEOUT_SECONDS = 60

  # Lazily memoised — `which` is cheap but we do it per-process not per-test.
  # Auth is intentionally NOT checked here: local devs rely on an interactive
  # `claude login` session (no env var present) and the CLI picks that up
  # automatically. CI sets CLAUDE_CODE_OAUTH_TOKEN via repo secret instead.
  def self.cli_available?
    return @cli_available if defined?(@cli_available)

    @cli_available = system("which", CLAUDE_CLI, out: File::NULL, err: File::NULL)
  end

  def cli_available?
    McpCliHelpers.cli_available?
  end

  # Boots a Puma server on a free port using Capybara's lightweight wrapper.
  # Returns "http://host:port" — no browser involved.
  def boot_test_server
    @capybara_server ||= Capybara::Server.new(Rails.application).boot
    "http://#{@capybara_server.host}:#{@capybara_server.port}"
  end

  # Writes a per-test `.mcp.json` that points the CLI at our test server
  # with a pre-issued Doorkeeper bearer token (skipping the OAuth UI
  # which is covered separately by OauthPkceFlowTest).
  #
  # @param base_url [String]
  # @param token [String]
  # @return [String] absolute path to the config file
  def write_mcp_config(base_url:, token:)
    config = {
      mcpServers: {
        growth_os: {
          # Streamable HTTP transport per the MCP spec; the CLI infers
          # transport from `url` (vs `command` for stdio), but stating it
          # explicitly is more robust across CLI versions.
          type: "http",
          url: "#{base_url}/mcp",
          headers: { "Authorization" => "Bearer #{token}" }
        }
      }
    }
    file = Tempfile.create([ "mcp-config-", ".json" ])
    file.write(JSON.generate(config))
    file.close
    file.path
  end

  # Invokes the CLI in `--print` non-interactive mode, with all MCP
  # permissions auto-allowed (we're testing the SERVER side, not the
  # CLI's own approval UX).
  #
  # @param prompt [String] the user prompt
  # @param config_path [String] path returned by `write_mcp_config`
  # @return [String] stdout
  def run_claude_cli(prompt, config_path:)
    # `--allowed-tools <tools...>` is variadic and will consume any
    # trailing positional args — including the prompt. Put the prompt
    # first (right after the binary) and all flags afterwards so the
    # variadic only swallows tool patterns.
    #
    # `--no-session-persistence` prevents each test run from leaving a
    # transient session on disk (otherwise they pile up in the
    # /resume picker and the IDE's session list). Only works with
    # --print, which we already use.
    # Pin to Sonnet — these tests just need a model capable enough to
    # follow a forceful tool-use prompt; spending Opus tokens on parity
    # checks is wasteful. Override with CLAUDE_TEST_MODEL when debugging.
    cmd = [
      CLAUDE_CLI,
      prompt,
      "--print",
      "--no-session-persistence",
      "--model", ENV.fetch("CLAUDE_TEST_MODEL", "sonnet"),
      "--mcp-config", config_path,
      "--permission-mode", "acceptEdits",
      "--allowed-tools", "mcp__growth_os__*"
    ]
    stdout, stderr, status = Open3.capture3(*cmd, stdin_data: "")
    unless status.success?
      raise "claude CLI failed (#{status.exitstatus}): #{stderr}\nstdout: #{stdout}"
    end

    stdout
  end
end
