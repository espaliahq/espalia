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
    # JSON-RPC numbers arrive as Integer or Float depending on whether the
    # client sent `1` or `1.0`. A decimal-valued parameter (e.g. a binding
    # weight) declares its type as Numeric so both pass param validation; it
    # advertises as a JSON Schema "number".
    Numeric    => "number",
    TrueClass  => "boolean",
    FalseClass => "boolean",
    # The Operations::Base `:boolean` sentinel (Ruby has no Boolean class).
    :boolean   => "boolean",
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

    schema = {
      type: "object",
      properties: properties.transform_keys(&:to_s),
      required: required,
      additionalProperties: false
    }
    schema.merge(constraint_schema)
  end

  # `requires_any_of` groups → JSON Schema, the only way to advertise a choice
  # between parameters (the flat `required` array above is an "all of").
  #
  # One group is a bare `anyOf`. Several groups must ALL hold, so they nest
  # under `allOf` — flattening their branches into one `anyOf` would say
  # "satisfy any one group", which is weaker than declared.
  #
  # Each branch carries ONLY `required`. `additionalProperties: false` doesn't
  # see into subschemas, so a branch that also declared `properties` would have
  # them rejected as additional — keep branches to `required` alone.
  #
  # @return [Hash] merged into the input schema (empty when unconstrained)
  def constraint_schema
    groups = @operation_class.parameter_constraints.map do |names|
      { anyOf: names.map { |name| { required: [ name.to_s ] } } }
    end

    case groups.size
    when 0 then {}
    when 1 then groups.first
    else { allOf: groups }
    end
  end

  def property_for(parameter)
    # An explicit schema fragment (declared via `parameter ..., schema:`)
    # wins verbatim — it's how a complex Hash/Array param advertises its
    # real shape instead of a bare `{ type: "object" }`.
    return parameter.schema if parameter.schema

    schema = { type: TYPE_MAPPING.fetch(parameter.type, "string") }
    schema[:enum] = parameter.allowed if parameter.allowed
    # `allow_blank: false` → the empty string is invalid. minLength is the
    # closest standard expression; the runtime is marginally stricter still
    # (it also rejects whitespace-only), which no keyword captures as simply.
    schema[:minLength] = 1 if parameter.allow_blank == false && schema[:type] == "string"
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
