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

  def schema_for(operation_class)
    Mcp::OperationToTool.call(operation_class)[:inputSchema]
  end

  BlankFixture = Class.new(Operations::Base) do
    parameter :name, String, allow_blank: false
    parameter :description, String
    parameter :level, Integer, allow_blank: false
    def policy_check = nil
    def perform = nil
  end

  context "allow_blank" do
    should "advertise minLength on a non-blankable string" do
      assert_equal({ type: "string", minLength: 1 }, schema_for(BlankFixture)[:properties]["name"])
    end

    should "leave a clearable string unconstrained" do
      assert_equal({ type: "string" }, schema_for(BlankFixture)[:properties]["description"])
    end

    # minLength is meaningless for a non-string — don't emit it.
    should "not emit minLength for a non-string parameter" do
      assert_equal({ type: "integer" }, schema_for(BlankFixture)[:properties]["level"])
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
    # branch declaring `properties` would have them rejected as additional.
    should "keep every branch to required alone" do
      branches = schema_for(OneGroupFixture)[:anyOf] +
                 schema_for(TwoGroupFixture)[:allOf].flat_map { |g| g[:anyOf] }

      branches.each { |branch| assert_equal [ :required ], branch.keys }
    end
  end
end
