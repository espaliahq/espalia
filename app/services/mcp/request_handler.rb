# frozen_string_literal: true

# JSON-RPC 2.0 dispatcher for the MCP server.
#
# Maps the small set of MCP methods we support today onto Ruby calls:
#   - `initialize`  → returns serverInfo + capabilities
#   - `tools/list`  → walks Operations::Registry, returns tool descriptors
#   - `tools/call`  → resolves the Operation, runs it, wraps the result
#                     into an MCP `content` array.
#
# Errors are translated into JSON-RPC error codes:
#   -32601 method not found
#   -32602 invalid params (Operations::Base::ParameterError)
#   -32603 internal error (Pundit denial, unexpected exceptions)
#
# The handler is stateless — one instance per request. The {AuthorizationContext}
# is supplied by the controller after Doorkeeper authenticates the bearer
# token; this class never inspects the request directly.
class Mcp::RequestHandler
  PROTOCOL_VERSION = "2025-06-18"
  SERVER_NAME = "growth_os"
  SERVER_VERSION = "0.1.0"

  # @param context [AuthorizationContext]
  # @param scopes [Doorkeeper::OAuth::Scopes, Array<String>, nil] scopes granted
  #   by the bearer token; used to gate write tools (read tools accept any
  #   scope, write/destructive tools require `write`).
  # @param client_application_id [String, nil] OAuth application id, recorded
  #   on PendingApproval rows so we can attribute who asked for what.
  # @param base_url [String, nil] root url of the server (e.g. "https://app.foo"),
  #   used to build the approval-review link in in-app handoff responses.
  def initialize(context:, scopes: nil, client_application_id: nil, base_url: nil)
    @context = context
    @scopes = Array(scopes).map(&:to_s)
    @client_application_id = client_application_id
    @base_url = base_url
  end

  # @param payload [Hash] a parsed JSON-RPC 2.0 request body
  # @return [Hash] a JSON-RPC 2.0 response body
  def call(payload)
    id = payload["id"]
    method = payload["method"]
    params = payload["params"] || {}

    result = dispatch(method, params)
    success(id, result)
  rescue MethodNotFound => e
    error(id, code: -32601, message: e.message)
  rescue Operations::Base::ParameterError => e
    error(id, code: -32602, message: e.message)
  rescue InsufficientScope => e
    error(id, code: -32603, message: "insufficient scope: #{e.message}")
  rescue Pundit::NotAuthorizedError => e
    error(id, code: -32603, message: "not authorized: #{e.message}")
  rescue StandardError => e
    Rails.logger.error("[mcp] #{e.class}: #{e.message}\n#{e.backtrace.first(10).join("\n")}")
    error(id, code: -32603, message: "internal error")
  end

  private

  class MethodNotFound < StandardError; end
  class InsufficientScope < StandardError; end

  def dispatch(method, params)
    case method
    when "initialize"  then handle_initialize(params)
    when "tools/list"  then handle_tools_list
    when "tools/call"  then handle_tools_call(params)
    else raise MethodNotFound, "unknown method: #{method}"
    end
  end

  def handle_initialize(_params)
    {
      protocolVersion: PROTOCOL_VERSION,
      capabilities: { tools: {} },
      serverInfo: { name: SERVER_NAME, version: SERVER_VERSION }
    }
  end

  def handle_tools_list
    tools = Operations::Registry.all
      .sort_by(&:name)
      .map { |op_class| Mcp::OperationToTool.call(op_class) }

    { tools: tools }
  end

  def handle_tools_call(params)
    name = params["name"]
    arguments = params["arguments"] || {}
    operation_class = Operations::Registry.find_by_tool_name(name)

    raise MethodNotFound, "unknown tool: #{name}" if operation_class.nil?

    enforce_scope!(operation_class)

    if operation_class.approval == :in_app
      return defer_to_in_app_approval(operation_class, arguments)
    end

    result = operation_class.call(context: @context, params: arguments)
    {
      content: [ { type: "text", text: JSON.generate(result) } ],
      isError: false
    }
  end

  # Persists a PendingApproval row instead of running the operation. The
  # MCP client gets back a URL the user can open to confirm — execution
  # happens in the web controller, never inside the MCP request.
  def defer_to_in_app_approval(operation_class, arguments)
    approval = Mcp::PendingApproval.create!(
      user: @context.user,
      tenant: @context.tenant_user&.tenant,
      client_application_id: @client_application_id,
      operation_class: operation_class.name,
      arguments: arguments,
      status: :pending,
      expires_at: Time.current + Mcp::PendingApproval::EXPIRY_WINDOW
    )

    review_url = build_review_url(approval)
    text = <<~MSG.strip
      Approval required for "#{operation_class.description}".
      Open #{review_url} to review and confirm.
      Expires at #{approval.expires_at.iso8601}.
    MSG

    {
      content: [ { type: "text", text: text } ],
      isError: false,
      meta: {
        approvalId: approval.id,
        approvalUrl: review_url,
        expiresAt: approval.expires_at.iso8601
      }
    }
  end

  def build_review_url(approval)
    path = Rails.application.routes.url_helpers.mcp_approval_path(approval)
    @base_url ? "#{@base_url}#{path}" : path
  end

  # Read operations accept either `read` or `write` scope. Anything else
  # (writes, destructive operations) requires `write` explicitly — clients
  # must request it at consent time. The MCP spec leaves per-tool scope
  # enforcement up to the server.
  def enforce_scope!(operation_class)
    required = (operation_class.category == :read) ? "read" : "write"
    return if @scopes.include?(required)
    # Read tools accept a `write` token too — escalation, not denial.
    return if operation_class.category == :read && @scopes.include?("write")

    raise InsufficientScope,
      "tool '#{Operations::Registry.tool_name_for(operation_class)}' requires scope '#{required}'"
  end

  def success(id, result)
    { jsonrpc: "2.0", id: id, result: result }
  end

  def error(id, code:, message:)
    { jsonrpc: "2.0", id: id, error: { code: code, message: message } }
  end
end
