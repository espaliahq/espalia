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
    render Components::Shell::PageLayout.new(
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
      h1(class: "text-2xl font-bold text-default") { "AI assistants" }
      p(class: "mt-1 text-sm text-muted") do
        plain "Connect an AI assistant to act on your behalf in this workspace via the " \
              "Model Context Protocol (MCP), and manage the ones already connected."
      end
    end
  end

  # ---- Connect ------------------------------------------------------------

  def connect_section
    section(class: "space-y-4") do
      div do
        h2(class: "text-lg font-semibold text-default") { "Connect an assistant" }
        p(class: "mt-1 text-sm text-muted") do
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
    render Components::Kit::Card.new do |card|
      card.body do
        p(class: "text-xs font-semibold text-muted uppercase tracking-wider mb-2") do
          plain "MCP server URL"
        end
        copyable(@mcp_url)
      end
    end
  end

  def client_card(name, &steps)
    render Components::Kit::Card.new(title: name) do |card|
      card.body(&steps)
    end
  end

  def claude_code_steps
    ol(class: "list-decimal list-outside ml-5 space-y-2 text-sm text-muted") do
      li do
        plain "Add the server from your terminal:"
        copyable("claude mcp add --transport http #{server_alias} #{@mcp_url}", class: "mt-2")
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
    ol(class: "list-decimal list-outside ml-5 space-y-2 text-sm text-muted") do
      li do
        plain "Open "
        strong { "Settings → Connectors" }
        plain " and choose "
        strong { "Add custom connector" }
        plain "."
      end
      li do
        plain "Name it "
        strong { product_name }
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
    ol(class: "list-decimal list-outside ml-5 space-y-2 text-sm text-muted") do
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
    ol(class: "list-decimal list-outside ml-5 space-y-2 text-sm text-muted") do
      li do
        plain "Add an entry to "
        inline_code("~/.codex/config.toml")
        plain ":"
        copyable("[mcp_servers.#{server_alias}]\nurl = \"#{@mcp_url}\"", multiline: true, class: "mt-2")
      end
      li do
        plain "Restart Codex. It opens a browser to authorise on first use, where you pick "
        plain "your workspace."
      end
    end
  end

  # The local name the snippets register the server under.
  def server_alias = product_name.parameterize

  # A copy-to-clipboard block: monospaced text plus a Copy button wired to
  # the `clipboard` Stimulus controller.
  def copyable(text, multiline: false, **attrs)
    base = "flex items-stretch gap-2"
    div(class: [ base, attrs[:class] ].compact.join(" "), data: { controller: "clipboard" }) do
      pre_class = "flex-1 min-w-0 overflow-x-auto rounded-lg bg-muted " \
                  "px-3 py-2 text-sm text-default font-mono"
      if multiline
        pre(class: pre_class, data: { clipboard_target: "source" }) { plain text }
      else
        # whitespace-nowrap keeps single-line commands/URLs on one line.
        div(class: "#{pre_class} whitespace-nowrap", data: { clipboard_target: "source" }) { plain text }
      end
      render Components::Kit::Button.new(variant: :outline, touch: true, class: "self-start",
                                         data: { action: "clipboard#copy", clipboard_target: "button" }) { "Copy" }
    end
  end

  def inline_code(text)
    code(class: "rounded bg-neutral-subtle px-1.5 py-0.5 text-sm font-mono text-default") do
      plain text
    end
  end

  # ---- Connected clients --------------------------------------------------

  def connected_section
    section(class: "space-y-4") do
      h2(class: "text-lg font-semibold text-default") { "Connected clients" }
      if @tokens.empty?
        empty_state
      else
        tokens_table
      end
    end
  end

  def empty_state
    render Components::Kit::EmptyState.new(title: "No MCP clients connected") do
      plain "Connect one using the steps above and it'll appear here."
    end
  end

  def tokens_table
    render Components::Kit::Card.new(variant: :flush) do
      div(class: "overflow-x-auto") { tokens_table_body }
    end
  end

  def tokens_table_body
    table(class: "w-full text-sm") do
      thead(class: "bg-subtle text-xs uppercase tracking-wider text-muted") do
        tr do
          th(class: "px-4 py-3 text-left") { "Client" }
          th(class: "px-4 py-3 text-left") { "Workspace" }
          th(class: "px-4 py-3 text-left") { "Scopes" }
          th(class: "px-4 py-3 text-left") { "Issued" }
          th(class: "px-4 py-3 text-right") { "" }
        end
      end
      tbody(class: "divide-y divide-subtle") do
        @tokens.each { |t| token_row(t) }
      end
    end
  end

  def token_row(token)
    tenant = @tenant_map[token.tenant_id]
    tr(class: "text-default") do
      td(class: "px-4 py-3 font-medium") { plain token.application.name }
      td(class: "px-4 py-3") { plain(tenant&.name || "—") }
      td(class: "px-4 py-3 text-muted") { plain token.scopes.to_s }
      td(class: "px-4 py-3 text-muted") { plain token.created_at.to_date.iso8601 }
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
      render Components::Kit::Button.new(
        variant: :outline, tone: :danger, size: :sm, touch: true, type: :submit,
        data: { turbo_confirm: "Revoke access for #{token.application.name}? They'll have to re-authorise." }
      ) { "Revoke" }
    end
  end
end
