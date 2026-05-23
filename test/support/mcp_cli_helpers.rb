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
# Skips with a clear message when the CLI binary isn't on PATH so
# developers without it installed still get green local runs; CI is
# expected to install @anthropic-ai/claude-code as a step.
module McpCliHelpers
  CLAUDE_CLI = ENV["CLAUDE_CLI"] || "claude"
  CLI_TIMEOUT_SECONDS = 60

  # Lazily memoised — `which` is cheap but we do it per-process not per-test.
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
    cmd = [
      CLAUDE_CLI,
      "--print",
      "--mcp-config", config_path,
      "--permission-mode", "acceptEdits",
      "--allowed-tools", "mcp__growth_os__*",
      prompt
    ]
    stdout, stderr, status = Open3.capture3(*cmd, stdin_data: "")
    unless status.success?
      raise "claude CLI failed (#{status.exitstatus}): #{stderr}\nstdout: #{stdout}"
    end

    stdout
  end
end
