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

  # Cross-parameter constraints → JSON Schema, the only way to advertise rules
  # the flat `required` array above (an "all of") can't express.
  #
  # Two kinds are emitted: `requires_any_of` groups as `anyOf`, and
  # `requires_when` declarations as `if`/`then`. One constraint is merged
  # bare; several must ALL hold, so they nest under `allOf` — flattening them
  # would say "satisfy any one", which is weaker than declared.
  #
  # A subschema names a property only where matching on its VALUE demands it
  # (`if`'s match, `then`'s non-blank keywords). `additionalProperties: false`
  # is evaluated against the top-level `properties` alone and never sees into
  # subschemas — which is why an `anyOf` branch must not introduce a property
  # name, and why these two may constrain one already declared at the top level.
  #
  # @return [Hash] merged into the input schema (empty when unconstrained)
  def constraint_schema
    constraints = any_of_groups + if_then_schemas

    case constraints.size
    when 0 then {}
    when 1 then constraints.first
    else { allOf: constraints }
    end
  end

  # @return [Array<Hash>] one `anyOf` per `requires_any_of` group
  def any_of_groups
    @operation_class.parameter_constraints.map do |names|
      { anyOf: names.map { |name| { required: [ name.to_s ] } } }
    end
  end

  # @return [Array<Hash>] one `if`/`then` per `requires_when` declaration
  def if_then_schemas
    @operation_class.conditional_requirements.map do |requirement|
      {
        if: {
          properties: { requirement.trigger.to_s => trigger_match(requirement) },
          # Without this, an instance that omits the trigger entirely matches
          # the `if` vacuously and gets held to the `then` branch.
          required: [ requirement.trigger.to_s ]
        },
        then: then_branch(requirement)
      }
    end
  end

  # `const` and a single-entry `enum` are equivalent in JSON Schema, so the
  # shape follows the value count rather than how it was declared — `equals: "x"`
  # and `in: ["x"]` publish identically.
  def trigger_match(requirement)
    values = requirement.values
    values.size == 1 ? { const: values.first } : { enum: values }
  end

  # The dependent must be present AND non-blank — `requires_when` enforces
  # exactly that at the boundary, so the branch says both rather than the
  # weaker "the key arrived".
  def then_branch(requirement)
    parameter = @operation_class.parameters.fetch(requirement.dependent)
    keywords = non_blank_keywords(TYPE_MAPPING.fetch(parameter.type, "string"))
    branch = { required: [ requirement.dependent.to_s ] }
    branch[:properties] = { requirement.dependent.to_s => keywords } if keywords.any?
    branch
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

    non_blank_keywords(type)
  end

  # The "not empty" keywords for a JSON Schema type. Shared with the
  # `requires_when` `then` branch so the two ways of saying non-blank stay in
  # step.
  #
  # @return [Hash] empty for a type with no emptiness keyword
  def non_blank_keywords(type)
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
