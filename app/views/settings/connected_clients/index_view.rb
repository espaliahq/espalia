# frozen_string_literal: true

# "AI assistants" settings page. Two jobs in one view:
#   1. Connect — step-by-step instructions for pointing an MCP-compatible
#      assistant (Claude Code, Claude.ai/Desktop, ChatGPT, Codex) at this
#      workspace, each with a copy-to-clipboard command/URL.
#   2. Connected clients — the MCP clients (Doorkeeper applications) that
#      currently hold a non-revoked access token for the signed-in user,
#      with a one-click revoke per client.
class Views::Settings::ConnectedClients::IndexView < Views::Base
  include Phlex::Rails::Helpers::Routes

  # @param tokens [Array<Mcp::AccessToken>] non-revoked tokens for current_user
  # @param mcp_url [String] absolute URL of the MCP endpoint (ends in /mcp)
  # @param tenant_map [Hash{String => Tenant}] id → Tenant preloaded by the controller
  # @param user [User, nil]
  # @param current_tenant [Tenant, nil]
  # @param tenants [Enumerable<Tenant>]
  def initialize(tokens:, mcp_url:, tenant_map: {}, user: nil, current_tenant: nil, tenants: [])
    @tokens = tokens
    @mcp_url = mcp_url
    @tenant_map = tenant_map
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants.to_a
  end

  def view_template
    render Components::Kit::PageLayout.new(
      user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      div(class: "max-w-3xl mx-auto space-y-8") do
        page_header
        connect_section
        connected_section
      end
    end
  end

  private

  def page_header
    div do
      h1(class: "text-2xl font-bold text-gray-900 dark:text-white") { "AI assistants" }
      p(class: "mt-1 text-sm text-gray-600 dark:text-gray-400") do
        plain "Connect an AI assistant to act on your behalf in this workspace via the " \
              "Model Context Protocol (MCP), and manage the ones already connected."
      end
    end
  end

  # ---- Connect ------------------------------------------------------------

  def connect_section
    section(class: "space-y-4") do
      div do
        h2(class: "text-lg font-semibold text-gray-900 dark:text-white") { "Connect an assistant" }
        p(class: "mt-1 text-sm text-gray-600 dark:text-gray-400") do
          plain "Point any MCP-compatible client at the server URL below. There are no API "
          plain "keys to paste — you'll sign in and pick a workspace in your browser when the "
          plain "client first connects."
        end
      end

      server_url_block
      client_card("Claude Code") { claude_code_steps }
      client_card("Claude.ai & Claude Desktop") { claude_app_steps }
      client_card("ChatGPT") { chatgpt_steps }
      client_card("Codex") { codex_steps }
    end
  end

  def server_url_block
    div(class: "bg-white dark:bg-gray-900 rounded-2xl shadow p-5") do
      p(class: "text-xs font-semibold text-gray-600 dark:text-gray-300 uppercase tracking-wider mb-2") do
        plain "MCP server URL"
      end
      copyable(@mcp_url)
    end
  end

  def client_card(name, &steps)
    div(class: "bg-white dark:bg-gray-900 rounded-2xl shadow p-5 space-y-3") do
      h3(class: "text-base font-semibold text-gray-900 dark:text-white") { name }
      steps.call
    end
  end

  def claude_code_steps
    ol(class: "list-decimal list-outside ml-5 space-y-2 text-sm text-gray-700 dark:text-gray-200") do
      li do
        plain "Add the server from your terminal:"
        copyable("claude mcp add --transport http growthos #{@mcp_url}", class: "mt-2")
      end
      li do
        plain "Run "
        inline_code("/mcp")
        plain " inside Claude Code and choose "
        strong { "Authenticate" }
        plain " — a browser window opens to approve access and pick your workspace."
      end
    end
  end

  def claude_app_steps
    ol(class: "list-decimal list-outside ml-5 space-y-2 text-sm text-gray-700 dark:text-gray-200") do
      li do
        plain "Open "
        strong { "Settings → Connectors" }
        plain " and choose "
        strong { "Add custom connector" }
        plain "."
      end
      li do
        plain "Name it "
        strong { "GrowthOS" }
        plain ", paste the server URL above, and save."
      end
      li do
        plain "Click "
        strong { "Connect" }
        plain " to approve access and pick your workspace in the browser."
      end
    end
  end

  def chatgpt_steps
    ol(class: "list-decimal list-outside ml-5 space-y-2 text-sm text-gray-700 dark:text-gray-200") do
      li do
        plain "In a plan that supports connectors, enable "
        strong { "Settings → Connectors → Advanced → Developer mode" }
        plain "."
      end
      li do
        plain "Choose "
        strong { "Create" }
        plain ", paste the server URL above as the MCP server URL, and save."
      end
      li { plain "Authenticate in the browser when prompted and select your workspace." }
    end
  end

  def codex_steps
    ol(class: "list-decimal list-outside ml-5 space-y-2 text-sm text-gray-700 dark:text-gray-200") do
      li do
        plain "Add an entry to "
        inline_code("~/.codex/config.toml")
        plain ":"
        copyable("[mcp_servers.growthos]\nurl = \"#{@mcp_url}\"", multiline: true, class: "mt-2")
      end
      li do
        plain "Restart Codex. It opens a browser to authorise on first use, where you pick "
        plain "your workspace."
      end
    end
  end

  # A copy-to-clipboard block: monospaced text plus a Copy button wired to
  # the `clipboard` Stimulus controller.
  def copyable(text, multiline: false, **attrs)
    base = "flex items-stretch gap-2"
    div(class: [ base, attrs[:class] ].compact.join(" "), data: { controller: "clipboard" }) do
      pre_class = "flex-1 min-w-0 overflow-x-auto rounded-lg bg-gray-50 dark:bg-gray-800 " \
                  "px-3 py-2 text-sm text-gray-900 dark:text-gray-100 font-mono"
      if multiline
        pre(class: pre_class, data: { clipboard_target: "source" }) { plain text }
      else
        # whitespace-nowrap keeps single-line commands/URLs on one line.
        div(class: "#{pre_class} whitespace-nowrap", data: { clipboard_target: "source" }) { plain text }
      end
      button(
        type: "button",
        class: "shrink-0 self-start min-h-11 rounded-lg border border-gray-300 dark:border-gray-600 " \
               "bg-white dark:bg-gray-900 px-3 text-sm font-medium text-gray-700 dark:text-gray-200 " \
               "hover:bg-gray-50 dark:hover:bg-gray-800",
        data: { action: "clipboard#copy", clipboard_target: "button" }
      ) { "Copy" }
    end
  end

  def inline_code(text)
    code(class: "rounded bg-gray-100 dark:bg-gray-800 px-1.5 py-0.5 text-sm font-mono text-gray-900 dark:text-gray-100") do
      plain text
    end
  end

  # ---- Connected clients --------------------------------------------------

  def connected_section
    section(class: "space-y-4") do
      h2(class: "text-lg font-semibold text-gray-900 dark:text-white") { "Connected clients" }
      if @tokens.empty?
        empty_state
      else
        tokens_table
      end
    end
  end

  def empty_state
    div(class: "rounded-2xl border border-dashed border-gray-300 dark:border-gray-700 p-8 text-center") do
      p(class: "text-sm text-gray-600 dark:text-gray-400") do
        plain "No MCP clients connected. Connect one using the steps above and it'll appear here."
      end
    end
  end

  def tokens_table
    div(class: "bg-white dark:bg-gray-900 rounded-2xl shadow overflow-hidden") do
      table(class: "w-full text-sm") do
        thead(class: "bg-gray-50 dark:bg-gray-800 text-xs uppercase tracking-wider text-gray-500") do
          tr do
            th(class: "px-4 py-3 text-left") { "Client" }
            th(class: "px-4 py-3 text-left") { "Workspace" }
            th(class: "px-4 py-3 text-left") { "Scopes" }
            th(class: "px-4 py-3 text-left") { "Issued" }
            th(class: "px-4 py-3 text-right") { "" }
          end
        end
        tbody(class: "divide-y divide-gray-100 dark:divide-gray-800") do
          @tokens.each { |t| token_row(t) }
        end
      end
    end
  end

  def token_row(token)
    tenant = @tenant_map[token.tenant_id]
    tr(class: "text-gray-900 dark:text-gray-100") do
      td(class: "px-4 py-3 font-medium") { plain token.application.name }
      td(class: "px-4 py-3") { plain(tenant&.name || "—") }
      td(class: "px-4 py-3 text-gray-600 dark:text-gray-400") { plain token.scopes.to_s }
      td(class: "px-4 py-3 text-gray-600 dark:text-gray-400") { plain token.created_at.to_date.iso8601 }
      td(class: "px-4 py-3 text-right") { revoke_button(token) }
    end
  end

  def revoke_button(token)
    form(
      action: settings_connected_client_path(token),
      method: :post,
      data: { turbo: "false" },
      class: "inline-block"
    ) do
      input(type: "hidden", name: "_method", value: "delete")
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      button(
        type: "submit",
        class: "rounded-lg border border-red-200 bg-white px-3 py-1.5 text-xs font-medium text-red-700 hover:bg-red-50",
        data: { turbo_confirm: "Revoke access for #{token.application.name}? They'll have to re-authorise." }
      ) { "Revoke" }
    end
  end
end
