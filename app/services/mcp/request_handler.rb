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
  def initialize(context:)
    @context = context
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
  rescue Pundit::NotAuthorizedError => e
    error(id, code: -32603, message: "not authorized: #{e.message}")
  rescue StandardError => e
    Rails.logger.error("[mcp] #{e.class}: #{e.message}\n#{e.backtrace.first(10).join("\n")}")
    error(id, code: -32603, message: "internal error")
  end

  private

  class MethodNotFound < StandardError; end

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

    result = operation_class.call(context: @context, params: arguments)
    {
      content: [ { type: "text", text: JSON.generate(result) } ],
      isError: false
    }
  end

  def success(id, result)
    { jsonrpc: "2.0", id: id, result: result }
  end

  def error(id, code:, message:)
    { jsonrpc: "2.0", id: id, error: { code: code, message: message } }
  end
end
