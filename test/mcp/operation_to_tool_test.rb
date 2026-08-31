# frozen_string_literal: true

require "test_helper"

# Unit tests for the Operation → MCP tool descriptor conversion. The committed
# snapshot (tool_registry_snapshot_test.rb) pins the real tool surface; this
# file exercises the conversion rules themselves, including shapes no shipped
# Operation uses yet.
class Mcp::OperationToToolTest < ActiveSupport::TestCase
  UnconstrainedFixture = Class.new(Operations::Base) do
    parameter :framework_id, String, required: true
    parameter :name, String
    def policy_check = nil
    def perform = nil
  end

  OneGroupFixture = Class.new(Operations::Base) do
    parameter :framework_id, String, required: true
    parameter :capability_id, String
    parameter :illustration_id, String
    requires_any_of :capability_id, :illustration_id
    def policy_check = nil
    def perform = nil
  end

  TwoGroupFixture = Class.new(Operations::Base) do
    parameter :a, String
    parameter :b, String
    parameter :c, String
    parameter :d, String
    requires_any_of :a, :b
    requires_any_of :c, :d
    def policy_check = nil
    def perform = nil
  end

  BlankFixture = Class.new(Operations::Base) do
    parameter :name, String, allow_blank: false
    parameter :description, String
    parameter :level, Integer, allow_blank: false
    def policy_check = nil
    def perform = nil
  end

  context "allow_blank" do
    # `\S` is the exact complement of String#blank?, so the advertised rule and
    # the enforced one agree on whitespace-only input rather than approximating.
    should "advertise a non-blank string precisely" do
      assert_equal(
        { type: "string", minLength: 1, pattern: "\\S" },
        schema_for(BlankFixture)[:properties]["name"]
      )
    end

    should "leave a clearable string unconstrained" do
      assert_equal({ type: "string" }, schema_for(BlankFixture)[:properties]["description"])
    end

    # minLength/pattern are meaningless for a non-string — don't emit them.
    should "not emit a string constraint for a non-string parameter" do
      assert_equal({ type: "integer" }, schema_for(BlankFixture)[:properties]["level"])
    end
  end

  ExplicitSchemaFixture = Class.new(Operations::Base) do
    parameter :anchor_id, String, allow_blank: false,
                                  schema: { type: "string", description: "Which one." }
    parameter :kind, String, allowed: %w[a b], schema: { description: "Which kind." }
    parameter :payload, Hash, allow_blank: false, schema: { type: "object", properties: {} }
    def policy_check = nil
    def perform = nil
  end

  # An explicit `schema:` describes shape; it must not silently discard the
  # constraints the other flags imply, or the published schema accepts input
  # the operation then rejects.
  context "an explicit schema fragment" do
    should "layer over the derived blank constraint, not replace it" do
      assert_equal(
        { type: "string", minLength: 1, pattern: "\\S", description: "Which one." },
        schema_for(ExplicitSchemaFixture)[:properties]["anchor_id"]
      )
    end

    should "keep a derived enum" do
      assert_equal(
        { type: "string", enum: %w[a b], description: "Which kind." },
        schema_for(ExplicitSchemaFixture)[:properties]["kind"]
      )
    end

    should "use the type's own emptiness keyword" do
      assert_equal(
        { type: "object", minProperties: 1, properties: {} },
        schema_for(ExplicitSchemaFixture)[:properties]["payload"]
      )
    end
  end

  context "cross-parameter constraints" do
    should "emit no anyOf when the operation declares none" do
      schema = schema_for(UnconstrainedFixture)

      assert_not schema.key?(:anyOf)
      assert_not schema.key?(:allOf)
      assert_equal %w[framework_id], schema[:required]
    end

    should "emit a bare anyOf for a single group" do
      schema = schema_for(OneGroupFixture)

      assert_equal(
        [ { required: [ "capability_id" ] }, { required: [ "illustration_id" ] } ],
        schema[:anyOf]
      )
      # The flat required list is unaffected — the two are ANDed by JSON Schema.
      assert_equal %w[framework_id], schema[:required]
    end

    # Several groups must ALL hold. Flattening their branches into one anyOf
    # would say "satisfy any one group", which is weaker than declared.
    should "nest several groups under allOf, not flatten them" do
      schema = schema_for(TwoGroupFixture)

      assert_not schema.key?(:anyOf)
      assert_equal(
        [
          { anyOf: [ { required: [ "a" ] }, { required: [ "b" ] } ] },
          { anyOf: [ { required: [ "c" ] }, { required: [ "d" ] } ] }
        ],
        schema[:allOf]
      )
    end

    # additionalProperties: false does not see into anyOf/allOf subschemas, so a
    # branch declaring a NEW property name would have it rejected as additional.
    # (An if/then subschema may constrain a name already declared at the top
    # level — see the requires_when context below.)
    should "keep every anyOf branch to required alone" do
      branches = schema_for(OneGroupFixture)[:anyOf] +
                 schema_for(TwoGroupFixture)[:allOf].flat_map { |g| g[:anyOf] }

      branches.each { |branch| assert_equal [ :required ], branch.keys }
    end
  end

  ConditionalFixture = Class.new(Operations::Base) do
    parameter :evidence_type, String, required: true, allowed: %w[note other]
    parameter :custom_type_label, String
    requires_when :custom_type_label, if: :evidence_type, equals: "other"
    def policy_check = nil
    def perform = nil
  end

  InSetConditionalFixture = Class.new(Operations::Base) do
    parameter :mapping_type, String, allowed: %w[same evolved split]
    parameter :to_stable_id, String
    parameter :level_ordinal, Integer
    requires_when :to_stable_id, if: :mapping_type, in: %w[evolved split]
    requires_when :level_ordinal, if: :mapping_type, equals: "split"
    def policy_check = nil
    def perform = nil
  end

  MixedConstraintFixture = Class.new(Operations::Base) do
    parameter :kind, String, allowed: %w[a b]
    parameter :label, String
    parameter :name, String
    requires_any_of :label, :name
    requires_when :label, if: :kind, equals: "b"
    def policy_check = nil
    def perform = nil
  end

  context "requires_when" do
    should "emit a bare if/then for a single equals declaration" do
      schema = schema_for(ConditionalFixture)

      assert_not schema.key?(:allOf)
      assert_equal(
        { properties: { "evidence_type" => { const: "other" } }, required: [ "evidence_type" ] },
        schema[:if]
      )
    end

    # The runtime demands present-and-non-blank, so the branch must say both —
    # otherwise the schema accepts `custom_type_label: ""` the op then rejects.
    should "require the dependent AND constrain it non-blank" do
      assert_equal(
        {
          required: [ "custom_type_label" ],
          properties: { "custom_type_label" => { minLength: 1, pattern: "\\S" } }
        },
        schema_for(ConditionalFixture)[:then]
      )
    end

    should "emit enum for an in: declaration and const for an equals: one" do
      branches = schema_for(InSetConditionalFixture)[:allOf]

      assert_equal({ enum: %w[evolved split] }, branches.first[:if][:properties]["mapping_type"])
      assert_equal({ const: "split" }, branches.last[:if][:properties]["mapping_type"])
    end

    # minLength/pattern are meaningless for a non-string dependent.
    should "omit string keywords for a non-string dependent" do
      branch = schema_for(InSetConditionalFixture)[:allOf].last

      assert_equal({ required: [ "level_ordinal" ] }, branch[:then])
    end

    should "nest a requires_any_of group and a conditional together under allOf" do
      schema = schema_for(MixedConstraintFixture)

      assert_not schema.key?(:anyOf)
      assert_not schema.key?(:if)
      assert_equal(
        [ { anyOf: [ { required: [ "label" ] }, { required: [ "name" ] } ] } ],
        schema[:allOf].select { |c| c.key?(:anyOf) }
      )
      assert_equal 1, schema[:allOf].count { |c| c.key?(:if) }
    end

    # An instance that omits the trigger must not match the `if` vacuously and
    # get held to the `then` branch.
    should "require the trigger key inside the if branch" do
      assert_equal [ "evidence_type" ], schema_for(ConditionalFixture)[:if][:required]
    end
  end

  private

  # @param operation_class [Class<Operations::Base>]
  # @return [Hash] the tool descriptor's inputSchema
  def schema_for(operation_class)
    Mcp::OperationToTool.call(operation_class)[:inputSchema]
  end
end
