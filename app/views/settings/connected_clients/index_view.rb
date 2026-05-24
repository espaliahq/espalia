# frozen_string_literal: true

# Settings page listing the MCP clients (Doorkeeper applications) that
# currently hold a non-revoked access token for the signed-in user.
# Includes a one-click revoke for each.
class Views::Settings::ConnectedClients::IndexView < Views::Base
  include Phlex::Rails::Helpers::Routes

  # @param tokens [Array<Mcp::AccessToken>] non-revoked tokens for current_user
  # @param tenant_map [Hash{String => Tenant}] id → Tenant preloaded by the controller
  # @param user [User, nil]
  # @param current_tenant [Tenant, nil]
  # @param tenants [Enumerable<Tenant>]
  def initialize(tokens:, tenant_map: {}, user: nil, current_tenant: nil, tenants: [])
    @tokens = tokens
    @tenant_map = tenant_map
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants.to_a
  end

  def view_template
    render Components::Kit::PageLayout.new(
      user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      div(class: "max-w-3xl mx-auto space-y-6") do
        page_header
        if @tokens.empty?
          empty_state
        else
          tokens_table
        end
      end
    end
  end

  private

  def page_header
    div do
      h1(class: "text-2xl font-bold text-gray-900 dark:text-white") { "Connected MCP clients" }
      p(class: "mt-1 text-sm text-gray-600 dark:text-gray-400") do
        plain "External clients (Claude Desktop, Claude Code, etc.) that hold an active token to act on your behalf."
      end
    end
  end

  def empty_state
    div(class: "rounded-2xl border border-dashed border-gray-300 dark:border-gray-700 p-8 text-center") do
      p(class: "text-sm text-gray-600 dark:text-gray-400") do
        plain "No MCP clients connected. Connect one via its OAuth flow and it'll appear here."
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
