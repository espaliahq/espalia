# frozen_string_literal: true

# Converts an {Operations::Base} subclass into an MCP tool descriptor.
#
# The MCP spec wants each tool to advertise:
#   - `name`            — stable identifier the client uses to call it
#   - `description`     — one-line human summary shown in tool pickers
#   - `inputSchema`     — JSON Schema for arguments
#   - `annotations`     — hints like `readOnlyHint` / `destructiveHint`
#                         that let clients pick a sensible approval UX
#
# Keeping this as a pure conversion class (no state) means the registry
# can call it lazily without booting any other infrastructure.
class Mcp::OperationToTool
  # Map Ruby parameter types to JSON Schema primitive types.
  TYPE_MAPPING = {
    String     => "string",
    Integer    => "integer",
    Float      => "number",
    TrueClass  => "boolean",
    FalseClass => "boolean",
    Hash       => "object",
    Array      => "array"
  }.freeze

  # @param operation_class [Class<Operations::Base>]
  # @return [Hash] MCP tool descriptor
  def self.call(operation_class)
    new(operation_class).call
  end

  def initialize(operation_class)
    @operation_class = operation_class
  end

  # @return [Hash]
  def call
    {
      name: tool_name,
      description: @operation_class.description.to_s,
      inputSchema: input_schema,
      annotations: annotations
    }
  end

  private

  def tool_name
    Operations::Registry.tool_name_for(@operation_class)
  end

  def input_schema
    properties = @operation_class.parameters.transform_values { |p| property_for(p) }
    required = @operation_class.parameters.values.select(&:required).map { |p| p.name.to_s }

    {
      type: "object",
      properties: properties.transform_keys(&:to_s),
      required: required,
      additionalProperties: false
    }
  end

  def property_for(parameter)
    schema = { type: TYPE_MAPPING.fetch(parameter.type, "string") }
    schema[:enum] = parameter.allowed if parameter.allowed
    schema
  end

  # Per the MCP tool annotations spec — clients use these to decide
  # whether to surface an approval prompt to the user. Read tools are
  # safe to auto-allow; destructive tools deserve extra friction.
  def annotations
    {
      readOnlyHint: @operation_class.category == :read,
      destructiveHint: @operation_class.category == :destructive,
      idempotentHint: @operation_class.category == :read
    }
  end
end
