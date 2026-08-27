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

  # An explicit `schema:` fragment describes the param's SHAPE — it's how a
  # complex Hash/Array advertises its real structure instead of a bare
  # `{ type: "object" }`. It layers ON TOP of the constraints derived from the
  # other flags rather than replacing them: an early return here silently drops
  # `enum` and the blank guard, shipping a schema that accepts input the
  # operation rejects (which is the whole class of bug this file guards).
  def property_for(parameter)
    derived_property(parameter).merge(parameter.schema || {})
  end

  def derived_property(parameter)
    type = TYPE_MAPPING.fetch(parameter.type, "string")
    schema = { type: type }
    schema[:enum] = parameter.allowed if parameter.allowed
    schema.merge(blank_constraint(parameter, type))
  end

  # `allow_blank: false` → an empty value is invalid, expressed with whichever
  # keyword the type uses.
  #
  # Strings carry `pattern` as well as `minLength`, because the runtime rejects
  # whitespace-only too: `\S` ("contains a non-whitespace character") is the
  # exact complement of Ruby's `String#blank?`, so the published rule and the
  # enforced one match rather than merely approximate each other. `minLength`
  # stays alongside it as the legible statement of intent — `\S` already
  # implies it, but a reader (or an LLM) shouldn't have to derive that.
  #
  # @return [Hash] empty when the parameter permits blank
  def blank_constraint(parameter, type)
    return {} unless parameter.allow_blank == false

    case type
    when "string" then { minLength: 1, pattern: "\\S" }
    when "array"  then { minItems: 1 }
    when "object" then { minProperties: 1 }
    else {}
    end
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
