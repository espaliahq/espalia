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
  SERVER_NAME = Rails.configuration.x.product_name.parameterize(separator: "_")
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
  #
  # Error handling policy:
  #
  # - Client-side errors (bad method, bad params, denial, not-found-by-id)
  #   log at WARN with a one-line "[mcp] <label>" prefix. They map to the
  #   appropriate JSON-RPC code per the spec.
  # - Server-side errors (anything else falling through) log at ERROR
  #   with the exception class + first 10 backtrace frames so Datadog /
  #   Render alarms scoped to `level:error AND [mcp]` only fire on real
  #   bugs, not on misuse.
  #
  # Every error response gets a log line — auth denials and parameter
  # validation failures previously emitted nothing, which made root-cause
  # work harder than it needed to be.
  def call(payload)
    id = payload["id"]
    method = payload["method"]
    params = coerce_params(payload["params"])

    result = dispatch(method, params)
    success(id, result)
  rescue MethodNotFound => e
    log_client_error("method not found", e, code: -32601)
    error(id, code: -32601, message: e.message)
  rescue InvalidParams => e
    log_client_error("invalid params", e, code: -32602)
    error(id, code: -32602, message: e.message)
  rescue Operations::Base::ParameterError => e
    log_client_error("invalid params", e, code: -32602)
    error(id, code: -32602, message: e.message)
  rescue ActiveRecord::RecordNotFound => e
    # Bad id from the client. -32602 invalid params, not -32603 internal error.
    log_client_error("not found", e, code: -32602)
    error(id, code: -32602, message: format_not_found(e))
  rescue InsufficientScope => e
    log_client_error("insufficient scope", e, code: -32603)
    error(id, code: -32603, message: "insufficient scope: #{e.message}")
  rescue Pundit::NotAuthorizedError => e
    log_client_error("not authorized", e, code: -32603)
    error(id, code: -32603, message: "not authorized: #{e.message}")
  rescue StandardError => e
    Rails.logger.error("[mcp] internal error: #{e.class}: #{e.message}\n#{e.backtrace.first(10).join("\n")}")
    error(id, code: -32603, message: "internal error")
  end

  private

  class MethodNotFound < StandardError; end
  class InsufficientScope < StandardError; end
  class InvalidParams < StandardError; end

  # JSON-RPC `params` MAY be omitted or be an object/array. We treat
  # missing as `{}`; anything that isn't a Hash is a client bug and
  # earns -32602 (invalid params), not -32603 (internal error).
  def coerce_params(raw)
    return {} if raw.nil?
    return raw if raw.is_a?(Hash)

    raise InvalidParams, "params must be a JSON object"
  end

  def dispatch(method, params)
    case method
    when "initialize"     then handle_initialize(params)
    when "tools/list"     then handle_tools_list
    when "tools/call"     then handle_tools_call(params)
    when "resources/list" then handle_resources_list
    when "resources/read" then handle_resources_read(params)
    else raise MethodNotFound, "unknown method: #{method}"
    end
  end

  def handle_initialize(_params)
    {
      protocolVersion: PROTOCOL_VERSION,
      capabilities: { tools: {}, resources: {} },
      serverInfo: { name: SERVER_NAME, version: SERVER_VERSION }
    }
  end

  def handle_resources_list
    { resources: Mcp::ResourceRegistry.list(context: @context) }
  end

  def handle_resources_read(params)
    uri = params["uri"].to_s
    payload = Mcp::ResourceRegistry.read(uri: uri, context: @context)
    {
      contents: [
        {
          uri: uri,
          mimeType: "application/json",
          text: JSON.generate(payload)
        }
      ]
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
    arguments = params["arguments"]
    arguments = {} if arguments.nil?
    raise InvalidParams, "arguments must be a JSON object" unless arguments.is_a?(Hash)
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
  #
  # The input shape is validated BEFORE the row is minted: otherwise a
  # malformed `:in_app` call is accepted here and only fails when the user
  # opens the review page, a dead end for both of them (and the client is told
  # nothing, since the deferral response looks like a success). Instantiating
  # runs the declared parameter rules and NOTHING else — policy checks and
  # entity lookups stay in `#call`, so deferral semantics are unchanged — and a
  # bad payload raises ParameterError, which `#call`'s rescue maps to -32602
  # like every other tool. The instance is discarded; approval executes from
  # the persisted arguments under a freshly-rebuilt context.
  def defer_to_in_app_approval(operation_class, arguments)
    operation_class.new(context: @context, params: arguments)

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

  # One-line log entry for client-attributable failures. WARN level so it
  # doesn't trip error alarms but stays searchable by `[mcp]` and by code.
  def log_client_error(label, exception, code:)
    summary = exception.message.to_s.gsub(/\s+/, " ").strip
    Rails.logger.warn("[mcp] #{label} (code=#{code}): #{exception.class}: #{summary[0, 300]}")
  end

  # ActiveRecord::RecordNotFound messages look like
  # `Couldn't find Foo with [WHERE foo.id = $1 AND ...]`. Strip the
  # SQL fragment for the public response (don't leak query shape) but
  # keep the model name so the client can self-correct.
  def format_not_found(exception)
    model = exception.message.scan(/Couldn't find (\S+)/).flatten.first
    model ? "not found: #{model}" : "not found"
  end
end
