# frozen_string_literal: true

require "test_helper"

# Unit tests for the Operations::Base DSL. Concrete operations are tested
# alongside the controllers/MCP tools that will consume them — this file
# exercises only the framework: parameter validation, category/approval
# defaults, the policy_check → perform pipeline, and authorize wiring.
class Operations::BaseTest < ActiveSupport::TestCase
  # Bare context — no models needed for DSL tests.
  def build_context
    AuthorizationContext.new(user: nil, tenant_user: nil, person: nil)
  end

  context "category DSL" do
    should "default to :read when unset" do
      op = Class.new(Operations::Base)
      assert_equal :read, op.category
    end

    should "accept a declared category" do
      op = Class.new(Operations::Base) { category :write }
      assert_equal :write, op.category
    end

    should "reject an unknown category" do
      assert_raises(ArgumentError) do
        Class.new(Operations::Base) { category :nuclear }
      end
    end
  end

  context "approval DSL" do
    should "default to :none for read" do
      op = Class.new(Operations::Base) { category :read }
      assert_equal :none, op.approval
    end

    should "default to :none for write (MCP client handles its own prompt)" do
      op = Class.new(Operations::Base) { category :write }
      assert_equal :none, op.approval
    end

    should "default to :in_app for destructive" do
      op = Class.new(Operations::Base) { category :destructive }
      assert_equal :in_app, op.approval
    end

    should "honour an explicit approval override" do
      op = Class.new(Operations::Base) do
        category :write
        approval :in_app
      end
      assert_equal :in_app, op.approval
    end

    should "reject an unknown approval" do
      assert_raises(ArgumentError) do
        Class.new(Operations::Base) { approval :magic }
      end
    end
  end

  ParamFixture = Class.new(Operations::Base) do
    parameter :framework_id, String, required: true
    parameter :name, String
    parameter :level, Integer, allowed: [ 1, 2, 3 ]
    def policy_check = nil
    def perform = params
  end

  AnyOfFixture = Class.new(Operations::Base) do
    parameter :framework_id, String, required: true
    parameter :name, String
    parameter :description, String
    parameter :is_entry, :boolean
    requires_any_of :name, :description, :is_entry
    def policy_check = nil
    def perform = params
  end

  context "requires_any_of DSL" do
    should "accept a call supplying one of the group" do
      out = AnyOfFixture.call(context: build_context, params: { framework_id: "fw_1", name: "Engineer" })
      assert_equal "Engineer", out[:name]
    end

    should "raise when none of the group is supplied" do
      err = assert_raises(Operations::Base::ParameterError) do
        AnyOfFixture.new(context: build_context, params: { framework_id: "fw_1" })
      end
      assert_match(/at least one of: name, description, is_entry/, err.message)
    end

    # "Supplied" means the key arrived, not that it carries a meaty value —
    # clearing a field is a legitimate partial update, and matches what the
    # emitted JSON Schema `required` asks.
    should "count a blank string as supplied" do
      out = AnyOfFixture.call(context: build_context, params: { framework_id: "fw_1", description: "" })
      assert_equal "", out[:description]
    end

    should "count false as supplied" do
      out = AnyOfFixture.call(context: build_context, params: { framework_id: "fw_1", is_entry: false })
      assert_equal false, out[:is_entry]
    end

    should "reject an undeclared parameter name at load time" do
      err = assert_raises(ArgumentError) do
        Class.new(Operations::Base) do
          parameter :name, String
          requires_any_of :name, :nope
        end
      end
      assert_match(/undeclared parameter/, err.message)
    end

    # A repeated name describes a group of one — i.e. a mandatory parameter,
    # not a choice — so it must not slip past the cardinality check.
    should "reject a group naming the same parameter twice" do
      assert_raises(ArgumentError) do
        Class.new(Operations::Base) do
          parameter :name, String
          requires_any_of :name, :name
        end
      end
    end

    should "reject a group of fewer than two parameters" do
      assert_raises(ArgumentError) do
        Class.new(Operations::Base) do
          parameter :name, String
          requires_any_of :name
        end
      end
    end
  end

  RequiresWhenFixture = Class.new(Operations::Base) do
    parameter :evidence_type, String, required: true, allowed: %w[note other]
    parameter :custom_type_label, String
    parameter :mapping_type, String, allowed: %w[same evolved split]
    parameter :to_stable_id, String
    requires_when :custom_type_label, if: :evidence_type, equals: "other"
    requires_when :to_stable_id, if: :mapping_type, in: %w[evolved split]
    def policy_check = nil
    def perform = params
  end

  context "requires_when DSL" do
    should "accept a call whose trigger doesn't match" do
      out = RequiresWhenFixture.call(context: build_context, params: { evidence_type: "note" })
      assert_nil out[:custom_type_label]
    end

    should "accept a call whose trigger is absent entirely" do
      out = RequiresWhenFixture.call(context: build_context, params: { evidence_type: "note" })
      assert_nil out[:mapping_type]
    end

    should "accept a matching trigger with the dependent supplied" do
      out = RequiresWhenFixture.call(
        context: build_context,
        params: { evidence_type: "other", custom_type_label: "Retro note" }
      )
      assert_equal "Retro note", out[:custom_type_label]
    end

    should "raise when the equals trigger matches and the dependent is missing" do
      err = assert_raises(Operations::Base::ParameterError) do
        RequiresWhenFixture.new(context: build_context, params: { evidence_type: "other" })
      end
      assert_match(/custom_type_label is required when evidence_type is "other"/, err.message)
    end

    # Conditionally required means conditionally mandatory — a blank value is
    # the mistake being caught, not a partial-update clear.
    should "raise when the dependent is supplied blank" do
      assert_raises(Operations::Base::ParameterError) do
        RequiresWhenFixture.new(
          context: build_context, params: { evidence_type: "other", custom_type_label: "" }
        )
      end
    end

    should "raise when the dependent is whitespace-only" do
      assert_raises(Operations::Base::ParameterError) do
        RequiresWhenFixture.new(
          context: build_context, params: { evidence_type: "other", custom_type_label: "   " }
        )
      end
    end

    should "raise naming the matched value for an in: group" do
      err = assert_raises(Operations::Base::ParameterError) do
        RequiresWhenFixture.new(
          context: build_context, params: { evidence_type: "note", mapping_type: "split" }
        )
      end
      assert_match(/to_stable_id is required when mapping_type is "split"/, err.message)
    end

    should "accept an in: trigger outside the matched set" do
      out = RequiresWhenFixture.call(
        context: build_context, params: { evidence_type: "note", mapping_type: "same" }
      )
      assert_nil out[:to_stable_id]
    end

    # Web controllers flash `e.message` verbatim, so a rule with established
    # domain copy can keep it instead of the generic parameter-speak.
    MessageOverrideFixture = Class.new(Operations::Base) do
      parameter :mapping_type, String, allowed: %w[same evolved split]
      parameter :to_stable_id, String
      parameter :note, String
      parameter :kind, String, allowed: %w[a b]
      requires_when :to_stable_id, if: :mapping_type, in: %w[evolved split],
                                   message: ->(type) { "#{type} mapping needs a survivor" }
      requires_when :note, if: :kind, equals: "b", message: "Tell us why"
      def policy_check = nil
      def perform = params
    end

    should "use a callable message override, passing the matched value" do
      err = assert_raises(Operations::Base::ParameterError) do
        MessageOverrideFixture.new(context: build_context, params: { mapping_type: "split" })
      end
      assert_equal "split mapping needs a survivor", err.message
    end

    should "use a String message override" do
      err = assert_raises(Operations::Base::ParameterError) do
        MessageOverrideFixture.new(context: build_context, params: { kind: "b" })
      end
      assert_equal "Tell us why", err.message
    end

    should "reject an undeclared dependent at load time" do
      err = assert_raises(ArgumentError) do
        Class.new(Operations::Base) do
          parameter :kind, String
          requires_when :nope, if: :kind, equals: "x"
        end
      end
      assert_match(/undeclared parameter/, err.message)
    end

    should "reject an undeclared trigger at load time" do
      assert_raises(ArgumentError) do
        Class.new(Operations::Base) do
          parameter :label, String
          requires_when :label, if: :nope, equals: "x"
        end
      end
    end

    should "reject declaring both equals: and in:" do
      err = assert_raises(ArgumentError) do
        Class.new(Operations::Base) do
          parameter :kind, String
          parameter :label, String
          requires_when :label, if: :kind, equals: "x", in: %w[x y]
        end
      end
      assert_match(/exactly one of equals: or in:/, err.message)
    end

    should "reject declaring neither equals: nor in:" do
      assert_raises(ArgumentError) do
        Class.new(Operations::Base) do
          parameter :kind, String
          parameter :label, String
          requires_when :label, if: :kind
        end
      end
    end

    should "reject an empty in: set" do
      assert_raises(ArgumentError) do
        Class.new(Operations::Base) do
          parameter :kind, String
          parameter :label, String
          requires_when :label, if: :kind, in: []
        end
      end
    end

    # `Array(hash)` would turn this into `[[key, value]]` — a constraint that
    # can never match anything.
    should "reject a non-Array in:" do
      err = assert_raises(ArgumentError) do
        Class.new(Operations::Base) do
          parameter :kind, String
          parameter :label, String
          requires_when :label, if: :kind, in: { a: 1 }
        end
      end
      assert_match(/in: needs an Array/, err.message)
    end

    # nil would arm the rule when the trigger is ABSENT — inexpressible in the
    # emitted `if`, whose `required` names the trigger.
    should "reject a nil match value" do
      err = assert_raises(ArgumentError) do
        Class.new(Operations::Base) do
          parameter :kind, String
          parameter :label, String
          requires_when :label, if: :kind, equals: nil
        end
      end
      assert_match(/JSON primitives/, err.message)
    end

    # A Symbol desyncs runtime (`:other != "other"`) from the published schema.
    should "reject a Symbol match value" do
      assert_raises(ArgumentError) do
        Class.new(Operations::Base) do
          parameter :kind, String
          parameter :label, String
          requires_when :label, if: :kind, in: [ :other ]
        end
      end
    end

    should "reject nil inside an in: set" do
      assert_raises(ArgumentError) do
        Class.new(Operations::Base) do
          parameter :kind, String
          parameter :label, String
          requires_when :label, if: :kind, in: [ "a", nil ]
        end
      end
    end

    # The caller's array is often a shared constant — a later mutation must not
    # change what is already enforced and advertised.
    should "snapshot the in: set against later mutation" do
      types = %w[evolved]
      op = Class.new(Operations::Base) do
        parameter :mapping_type, String
        parameter :to_stable_id, String
        requires_when :to_stable_id, if: :mapping_type, in: types
        def policy_check = nil
        def perform = params
      end
      types << "split"

      assert_equal %w[evolved], op.conditional_requirements.first.values
      out = op.call(context: build_context, params: { mapping_type: "split" })
      assert_nil out[:to_stable_id]
    end

    # Freezing the array alone leaves its String elements shared with the
    # caller — mutating one would change enforcement and the schema after load.
    should "snapshot String match values against later mutation" do
      equals_value = +"other"
      in_value = +"evolved"
      op = Class.new(Operations::Base) do
        parameter :kind, String
        parameter :label, String
        parameter :mapping_type, String
        parameter :to_stable_id, String
        requires_when :label, if: :kind, equals: equals_value
        requires_when :to_stable_id, if: :mapping_type, in: [ in_value ]
      end
      equals_value << "!"
      in_value << "!"

      assert_equal [ "other" ], op.conditional_requirements.first.values
      assert_equal [ "evolved" ], op.conditional_requirements.last.values
    end

    # NaN/Infinity are Floats but have no JSON encoding (RFC 8259), so the
    # schema could never publish them.
    should "reject a non-finite Float match value" do
      err = assert_raises(ArgumentError) do
        Class.new(Operations::Base) do
          parameter :weight, Numeric
          parameter :label, String
          requires_when :label, if: :weight, equals: Float::NAN
        end
      end
      assert_match(/JSON primitives/, err.message)
    end

    # A typo'd enum value declares a rule that can never fire — catch it at
    # load time rather than shipping a dead constraint.
    should "reject a matched value outside the trigger's allowed set" do
      err = assert_raises(ArgumentError) do
        Class.new(Operations::Base) do
          parameter :kind, String, allowed: %w[note other]
          parameter :label, String
          requires_when :label, if: :kind, equals: "otehr"
        end
      end
      assert_match(/outside kind.s allowed set/, err.message)
    end

    should "reject a parameter depending on itself" do
      assert_raises(ArgumentError) do
        Class.new(Operations::Base) do
          parameter :kind, String
          requires_when :kind, if: :kind, equals: "x"
        end
      end
    end
  end

  MustBeFixture = Class.new(Operations::Base) do
    parameter :role, String, allowed: %w[role_lead viewer]
    parameter :scope_type, String, allowed: %w[role capability]
    requires_when :scope_type, if: :role, equals: "role_lead", must_be: "role"
    def policy_check = nil
    def perform = params
  end

  context "requires_when must_be:" do
    should "accept the pinned value" do
      out = MustBeFixture.call(context: build_context, params: { role: "role_lead", scope_type: "role" })
      assert_equal "role", out[:scope_type]
    end

    should "raise when the dependent carries a different allowed value" do
      err = assert_raises(Operations::Base::ParameterError) do
        MustBeFixture.new(context: build_context, params: { role: "role_lead", scope_type: "capability" })
      end
      assert_match(/scope_type must be "role" when role is "role_lead"/, err.message)
    end

    should "still raise when the dependent is missing" do
      assert_raises(Operations::Base::ParameterError) do
        MustBeFixture.new(context: build_context, params: { role: "role_lead" })
      end
    end

    should "leave the dependent unconstrained when the trigger doesn't match" do
      out = MustBeFixture.call(context: build_context, params: { role: "viewer", scope_type: "capability" })
      assert_equal "capability", out[:scope_type]
    end

    should "reject a pin outside the dependent's allowed set at load time" do
      err = assert_raises(ArgumentError) do
        Class.new(Operations::Base) do
          parameter :role, String
          parameter :scope_type, String, allowed: %w[role capability]
          requires_when :scope_type, if: :role, equals: "role_lead", must_be: "nope"
        end
      end
      assert_match(/outside scope_type's allowed set/, err.message)
    end

    # A pin the dependent can never hold publishes `{type: "integer", const:
    # "5"}` — a schema that contradicts itself.
    should "reject a pin the dependent's declared type can't hold" do
      err = assert_raises(ArgumentError) do
        Class.new(Operations::Base) do
          parameter :role, String
          parameter :level_ordinal, Integer
          requires_when :level_ordinal, if: :role, equals: "role_lead", must_be: "5"
        end
      end
      assert_match(/is not a Integer/, err.message)
    end

    should "accept an Integer pin on a Numeric parameter" do
      op = Class.new(Operations::Base) do
        parameter :role, String
        parameter :weight, Numeric
        requires_when :weight, if: :role, equals: "role_lead", must_be: 1
        def policy_check = nil
        def perform = params
      end

      assert_equal 1, op.call(context: build_context, params: { role: "role_lead", weight: 1 })[:weight]
    end

    should "accept a boolean pin on a :boolean parameter" do
      op = Class.new(Operations::Base) do
        parameter :role, String
        parameter :is_entry, :boolean
        requires_when :is_entry, if: :role, equals: "role_lead", must_be: true
        def policy_check = nil
        def perform = params
      end

      assert_raises(Operations::Base::ParameterError) do
        op.new(context: build_context, params: { role: "role_lead", is_entry: false })
      end
      assert_equal true, op.call(
        context: build_context, params: { role: "role_lead", is_entry: "1" }
      )[:is_entry]
    end

    should "reject a non-boolean pin on a :boolean parameter" do
      assert_raises(ArgumentError) do
        Class.new(Operations::Base) do
          parameter :role, String
          parameter :is_entry, :boolean
          requires_when :is_entry, if: :role, equals: "role_lead", must_be: "yes"
        end
      end
    end

    should "reject a non-JSON-primitive pin at load time" do
      err = assert_raises(ArgumentError) do
        Class.new(Operations::Base) do
          parameter :role, String
          parameter :scope_type, String
          requires_when :scope_type, if: :role, equals: "role_lead", must_be: :role
        end
      end
      assert_match(/must_be value must be JSON primitives/, err.message)
    end

    # A pin is meaningless on a rule that forbids the dependent outright, so it
    # must not be silently swallowed.
    should "reject must_be: on forbids_when at load time" do
      err = assert_raises(ArgumentError) do
        Class.new(Operations::Base) do
          parameter :role, String
          parameter :scope_type, String
          forbids_when :scope_type, if: :role, equals: "viewer", must_be: "role"
        end
      end
      assert_match(/forbids_when got unknown option\(s\): must_be/, err.message)
    end
  end

  ForbidsWhenFixture = Class.new(Operations::Base) do
    parameter :mapping_type, String, allowed: %w[same evolved split archived]
    parameter :to_stable_id, String
    parameter :kind, String, allowed: %w[a b]
    parameter :note, String
    forbids_when :to_stable_id, if: :mapping_type, in: %w[same archived]
    forbids_when :note, if: :kind, equals: "a"
    def policy_check = nil
    def perform = params
  end

  context "forbids_when DSL" do
    should "accept a call whose trigger doesn't match" do
      out = ForbidsWhenFixture.call(
        context: build_context, params: { mapping_type: "evolved", to_stable_id: "cap_1" }
      )
      assert_equal "cap_1", out[:to_stable_id]
    end

    should "accept a matching trigger with the dependent omitted" do
      out = ForbidsWhenFixture.call(context: build_context, params: { mapping_type: "same" })
      assert_nil out[:to_stable_id]
    end

    # An explicit nil is how a controller compacts an inapplicable field, so it
    # must read as "not supplied" — the same reading `requires_any_of` uses.
    should "accept a matching trigger with the dependent explicitly nil" do
      out = ForbidsWhenFixture.call(
        context: build_context, params: { mapping_type: "archived", to_stable_id: nil }
      )
      assert_nil out[:to_stable_id]
    end

    should "raise when an in: trigger matches and the dependent is supplied" do
      err = assert_raises(Operations::Base::ParameterError) do
        ForbidsWhenFixture.new(
          context: build_context, params: { mapping_type: "same", to_stable_id: "cap_1" }
        )
      end
      assert_match(/to_stable_id is not accepted when mapping_type is "same"/, err.message)
    end

    should "raise when an equals trigger matches and the dependent is supplied" do
      err = assert_raises(Operations::Base::ParameterError) do
        ForbidsWhenFixture.new(context: build_context, params: { kind: "a", note: "why" })
      end
      assert_match(/note is not accepted when kind is "a"/, err.message)
    end

    # The emitted `not: { required: [dep] }` objects to the key EXISTING, so a
    # blank value violates it too — an inapplicable field is one the caller
    # should not send at all.
    should "raise when the dependent is supplied blank" do
      assert_raises(Operations::Base::ParameterError) do
        ForbidsWhenFixture.new(
          context: build_context, params: { mapping_type: "same", to_stable_id: "" }
        )
      end
    end

    ForbidMessageFixture = Class.new(Operations::Base) do
      parameter :mapping_type, String, allowed: %w[same evolved]
      parameter :to_stable_id, String
      parameter :kind, String, allowed: %w[a b]
      parameter :note, String
      forbids_when :to_stable_id, if: :mapping_type, in: %w[same],
                                  message: ->(type) { "a #{type} mapping takes no survivor" }
      forbids_when :note, if: :kind, equals: "a", message: "No note for a"
      def policy_check = nil
      def perform = params
    end

    should "use a callable message override, passing the matched value" do
      err = assert_raises(Operations::Base::ParameterError) do
        ForbidMessageFixture.new(
          context: build_context, params: { mapping_type: "same", to_stable_id: "cap_1" }
        )
      end
      assert_equal "a same mapping takes no survivor", err.message
    end

    should "use a String message override" do
      err = assert_raises(Operations::Base::ParameterError) do
        ForbidMessageFixture.new(context: build_context, params: { kind: "a", note: "why" })
      end
      assert_equal "No note for a", err.message
    end

    should "reject an undeclared dependent at load time" do
      err = assert_raises(ArgumentError) do
        Class.new(Operations::Base) do
          parameter :kind, String
          forbids_when :nope, if: :kind, equals: "x"
        end
      end
      assert_match(/forbids_when names undeclared parameter/, err.message)
    end

    should "reject an undeclared trigger at load time" do
      assert_raises(ArgumentError) do
        Class.new(Operations::Base) do
          parameter :label, String
          forbids_when :label, if: :nope, equals: "x"
        end
      end
    end

    should "reject a parameter forbidding itself" do
      assert_raises(ArgumentError) do
        Class.new(Operations::Base) do
          parameter :kind, String
          forbids_when :kind, if: :kind, equals: "x"
        end
      end
    end

    should "reject declaring both equals: and in:" do
      err = assert_raises(ArgumentError) do
        Class.new(Operations::Base) do
          parameter :kind, String
          parameter :label, String
          forbids_when :label, if: :kind, equals: "x", in: %w[x y]
        end
      end
      assert_match(/forbids_when needs exactly one of equals: or in:/, err.message)
    end

    should "reject declaring neither equals: nor in:" do
      assert_raises(ArgumentError) do
        Class.new(Operations::Base) do
          parameter :kind, String
          parameter :label, String
          forbids_when :label, if: :kind
        end
      end
    end

    should "reject a non-Array in:" do
      err = assert_raises(ArgumentError) do
        Class.new(Operations::Base) do
          parameter :kind, String
          parameter :label, String
          forbids_when :label, if: :kind, in: { a: 1 }
        end
      end
      assert_match(/forbids_when in: needs an Array/, err.message)
    end

    should "reject an empty in: set" do
      assert_raises(ArgumentError) do
        Class.new(Operations::Base) do
          parameter :kind, String
          parameter :label, String
          forbids_when :label, if: :kind, in: []
        end
      end
    end

    should "reject a non-JSON-primitive match value" do
      err = assert_raises(ArgumentError) do
        Class.new(Operations::Base) do
          parameter :kind, String
          parameter :label, String
          forbids_when :label, if: :kind, equals: :other
        end
      end
      assert_match(/JSON primitives/, err.message)
    end

    should "reject a non-finite Float match value" do
      assert_raises(ArgumentError) do
        Class.new(Operations::Base) do
          parameter :weight, Numeric
          parameter :label, String
          forbids_when :label, if: :weight, equals: Float::INFINITY
        end
      end
    end

    should "reject a matched value outside the trigger's allowed set" do
      err = assert_raises(ArgumentError) do
        Class.new(Operations::Base) do
          parameter :kind, String, allowed: %w[a b]
          parameter :label, String
          forbids_when :label, if: :kind, equals: "c"
        end
      end
      assert_match(/outside kind.s allowed set/, err.message)
    end

    should "snapshot the in: set against later mutation" do
      types = %w[same]
      op = Class.new(Operations::Base) do
        parameter :mapping_type, String
        parameter :to_stable_id, String
        forbids_when :to_stable_id, if: :mapping_type, in: types
        def policy_check = nil
        def perform = params
      end
      types << "archived"

      assert_equal %w[same], op.conditional_prohibitions.first.values
      out = op.call(context: build_context, params: { mapping_type: "archived", to_stable_id: "x" })
      assert_equal "x", out[:to_stable_id]
    end

    # The two declarations are independent rules on one parameter: requiring it
    # for one trigger value must not weaken forbidding it for another.
    should "compose with requires_when on the same parameter" do
      op = Class.new(Operations::Base) do
        parameter :mapping_type, String, allowed: %w[same evolved]
        parameter :to_stable_id, String
        requires_when :to_stable_id, if: :mapping_type, equals: "evolved"
        forbids_when :to_stable_id, if: :mapping_type, equals: "same"
        def policy_check = nil
        def perform = params
      end

      assert_raises(Operations::Base::ParameterError) do
        op.new(context: build_context, params: { mapping_type: "evolved" })
      end
      assert_raises(Operations::Base::ParameterError) do
        op.new(context: build_context, params: { mapping_type: "same", to_stable_id: "x" })
      end
      assert_equal "x", op.call(
        context: build_context, params: { mapping_type: "evolved", to_stable_id: "x" }
      )[:to_stable_id]
    end
  end

  DependentRequiredFixture = Class.new(Operations::Base) do
    parameter :mapping_type, String, allowed: %w[same evolved]
    parameter :to_stable_id, String
    dependent_required :to_stable_id, requires: :mapping_type
    def policy_check = nil
    def perform = params
  end

  context "dependent_required DSL" do
    should "accept both supplied" do
      out = DependentRequiredFixture.call(
        context: build_context, params: { mapping_type: "evolved", to_stable_id: "cap_1" }
      )
      assert_equal "cap_1", out[:to_stable_id]
    end

    should "accept neither supplied" do
      out = DependentRequiredFixture.call(context: build_context, params: {})
      assert_nil out[:to_stable_id]
    end

    # The gap requires_when/forbids_when leave: both arm on the trigger's
    # VALUE, so an absent trigger fires neither and the dependent is dropped.
    should "raise when the dependent is supplied without its obligation" do
      err = assert_raises(Operations::Base::ParameterError) do
        DependentRequiredFixture.new(context: build_context, params: { to_stable_id: "cap_1" })
      end
      assert_match(/mapping_type is required when to_stable_id is supplied/, err.message)
    end

    should "accept a nil dependent as not supplied" do
      out = DependentRequiredFixture.call(context: build_context, params: { to_stable_id: nil })
      assert_nil out[:to_stable_id]
    end

    should "use a String message override" do
      op = Class.new(Operations::Base) do
        parameter :a, String
        parameter :b, String
        dependent_required :a, requires: :b, message: "b goes with a"
        def policy_check = nil
        def perform = params
      end

      err = assert_raises(Operations::Base::ParameterError) do
        op.new(context: build_context, params: { a: "x" })
      end
      assert_equal "b goes with a", err.message
    end

    should "reject an undeclared parameter at load time" do
      err = assert_raises(ArgumentError) do
        Class.new(Operations::Base) do
          parameter :a, String
          dependent_required :a, requires: :nope
        end
      end
      assert_match(/dependent_required names undeclared parameter/, err.message)
    end

    should "reject a parameter depending on itself" do
      assert_raises(ArgumentError) do
        Class.new(Operations::Base) do
          parameter :a, String
          dependent_required :a, requires: :a
        end
      end
    end

    # An always-present obligation makes the rule dead — the same class of
    # mistake as a match value outside its trigger's enum.
    should "reject an obligation that is already unconditionally required" do
      err = assert_raises(ArgumentError) do
        Class.new(Operations::Base) do
          parameter :a, String
          parameter :b, String, required: true
          dependent_required :a, requires: :b
        end
      end
      assert_match(/already required — the rule can never fire/, err.message)
    end
  end

  BlankFixture = Class.new(Operations::Base) do
    parameter :name, String, allow_blank: false
    parameter :description, String
    def policy_check = nil
    def perform = params
  end

  context "allow_blank" do
    should "reject a supplied blank string" do
      err = assert_raises(Operations::Base::ParameterError) do
        BlankFixture.new(context: build_context, params: { name: "" })
      end
      assert_match(/name can't be blank/, err.message)
    end

    should "reject a whitespace-only string" do
      assert_raises(Operations::Base::ParameterError) do
        BlankFixture.new(context: build_context, params: { name: "   " })
      end
    end

    # Distinct from `required:` — omitting the key entirely is fine (that's a
    # partial update); only sending an empty value is the mistake.
    should "accept the parameter being omitted" do
      out = BlankFixture.call(context: build_context, params: {})
      assert_nil out[:name]
    end

    should "leave other parameters clearable" do
      out = BlankFixture.call(context: build_context, params: { description: "" })
      assert_equal "", out[:description]
    end
  end

  context "an explicit schema: fragment" do
    # Normalised at declaration time so the descriptor's merge is plain — a
    # String-keyed "type" must override the derived :type, not sit beside it.
    should "symbolise a string-keyed fragment" do
      op = Class.new(Operations::Base) do
        parameter :payload, Hash, schema: {
          "type" => "object", "properties" => { "name" => { "type" => "string" } }
        }
      end

      assert_equal(
        { type: "object", properties: { name: { type: "string" } } },
        op.parameters[:payload].schema
      )
    end

    # Fragments are often shared constants; a later mutation must not change
    # what is already advertised.
    should "deep-freeze the fragment's containers" do
      op = Class.new(Operations::Base) do
        parameter :payload, Hash, schema: { type: "object", properties: { name: { type: "string" } } }
      end
      fragment = op.parameters[:payload].schema

      assert fragment.frozen?
      assert fragment[:properties].frozen?
      assert fragment[:properties][:name].frozen?
    end
  end

  context "parameter validation" do
    should "raise when a required parameter is missing" do
      err = assert_raises(Operations::Base::ParameterError) do
        ParamFixture.new(context: build_context, params: {})
      end
      assert_match(/framework_id/, err.message)
    end

    should "accept symbol or string keys" do
      out = ParamFixture.call(context: build_context, params: { "framework_id" => "fw_1" })
      assert_equal "fw_1", out[:framework_id]
    end

    should "raise on type mismatch" do
      err = assert_raises(Operations::Base::ParameterError) do
        ParamFixture.new(context: build_context, params: { framework_id: 42 })
      end
      assert_match(/must be a String/, err.message)
    end

    should "raise when value is outside allowed set" do
      err = assert_raises(Operations::Base::ParameterError) do
        ParamFixture.new(
          context: build_context,
          params: { framework_id: "fw_1", level: 9 }
        )
      end
      assert_match(/must be one of/, err.message)
    end

    should "pass when an optional parameter is omitted" do
      out = ParamFixture.call(context: build_context, params: { framework_id: "fw_1" })
      assert_nil out[:name]
    end

    should "accept ActionController::Parameters" do
      ac_params = ActionController::Parameters.new(framework_id: "fw_1", name: "Eng")
      out = ParamFixture.call(context: build_context, params: ac_params)
      assert_equal "Eng", out[:name]
    end
  end

  BooleanFixture = Class.new(Operations::Base) do
    parameter :flag, :boolean
    parameter :required_flag, :boolean, required: true
    def policy_check = nil
    def perform = params
  end

  context ":boolean parameter" do
    should "pass true and false through" do
      out = BooleanFixture.call(context: build_context, params: { flag: true, required_flag: false })
      assert_equal true, out[:flag]
      assert_equal false, out[:required_flag]
    end

    should "cast the boolean-ish strings web forms submit" do
      out = BooleanFixture.call(context: build_context, params: { flag: "1", required_flag: "false" })
      assert_equal true, out[:flag]
      assert_equal false, out[:required_flag]
    end

    should "reject an unrecognisable value rather than coerce it truthy" do
      err = assert_raises(Operations::Base::ParameterError) do
        BooleanFixture.new(context: build_context, params: { flag: "banana", required_flag: true })
      end
      assert_match(/flag must be a boolean/, err.message)
    end

    should "treat a missing optional boolean as nil (not false)" do
      out = BooleanFixture.call(context: build_context, params: { required_flag: true })
      assert_nil out[:flag]
    end

    should "still enforce required" do
      err = assert_raises(Operations::Base::ParameterError) do
        BooleanFixture.new(context: build_context, params: {})
      end
      assert_match(/required_flag/, err.message)
    end
  end

  context "#call pipeline" do
    should "invoke policy_check before perform" do
      events = []
      op = Class.new(Operations::Base) do
        define_method(:policy_check) { events << :policy }
        define_method(:perform)      { events << :perform; :done }
      end

      result = op.call(context: build_context, params: {})

      assert_equal :done, result
      assert_equal %i[policy perform], events
    end

    should "raise NotImplementedError when subclass omits policy_check" do
      op = Class.new(Operations::Base) { def perform = nil }
      assert_raises(NotImplementedError) do
        op.call(context: build_context, params: {})
      end
    end

    should "raise NotImplementedError when subclass omits perform" do
      op = Class.new(Operations::Base) { def policy_check = nil }
      assert_raises(NotImplementedError) do
        op.call(context: build_context, params: {})
      end
    end

    should "forward authorize to Pundit with the context (+ optional policy_class)" do
      record = Object.new
      seen = nil
      # Matches Pundit.authorize's controller-side signature including
      # the policy_class: kwarg — Operations::Base#authorize now passes
      # it through so callers can override the inferred policy class.
      authorize_stub = lambda do |user, rec, query, policy_class: nil|
        seen = { user: user, record: rec, query: query, policy_class: policy_class }
        rec
      end

      op_class = Class.new(Operations::Base) do
        define_method(:policy_check) { authorize(record, :show?) }
        define_method(:perform) { :ok }
      end

      ctx = build_context
      result = Pundit.stub(:authorize, authorize_stub) do
        op_class.call(context: ctx, params: {})
      end

      assert_equal :ok, result
      assert_same ctx, seen[:user]
      assert_same record, seen[:record]
      assert_equal :show?, seen[:query]
      assert_nil seen[:policy_class]
    end

    should "forward an explicit policy_class to Pundit when supplied" do
      record = Object.new
      seen_class = nil
      custom_policy = Class.new
      authorize_stub = lambda do |_user, rec, _query, policy_class: nil|
        seen_class = policy_class
        rec
      end

      op_class = Class.new(Operations::Base) do
        define_method(:policy_check) { authorize(record, :show?, policy_class: custom_policy) }
        define_method(:perform) { :ok }
      end

      Pundit.stub(:authorize, authorize_stub) do
        op_class.call(context: build_context, params: {})
      end

      assert_same custom_policy, seen_class
    end

    should "block a non-read operation while impersonating" do
      op = Class.new(Operations::Base) do
        category :write
        def policy_check = nil
        def perform = :wrote
      end

      AuditMetadata.with(acting_via: :web, actor_id: "target", impersonation_active: true) do
        assert_raises(Operations::Base::ImpersonationReadOnlyError) do
          op.call(context: build_context, params: {})
        end
      end
    end

    should "block a non-read operation while impersonating even when the admin has no Person" do
      op = Class.new(Operations::Base) do
        category :write
        def policy_check = nil
        def perform = :wrote
      end

      # impersonator_id is nil (no linked admin Person) but the flag is set —
      # the guard must still fire.
      AuditMetadata.with(acting_via: :web, actor_id: "target", impersonation_active: true) do
        assert_raises(Operations::Base::ImpersonationReadOnlyError) do
          op.call(context: build_context, params: {})
        end
      end
    end

    should "allow a read operation while impersonating" do
      op = Class.new(Operations::Base) do
        category :read
        def policy_check = nil
        def perform = :read_ok
      end

      result = AuditMetadata.with(acting_via: :web, actor_id: "target", impersonation_active: true) do
        op.call(context: build_context, params: {})
      end
      assert_equal :read_ok, result
    end

    should "allow a write operation when not impersonating" do
      op = Class.new(Operations::Base) do
        category :write
        def policy_check = nil
        def perform = :wrote
      end

      result = AuditMetadata.with(acting_via: :web, actor_id: "target") do
        op.call(context: build_context, params: {})
      end
      assert_equal :wrote, result
    end

    should "propagate Pundit::NotAuthorizedError raised by authorize" do
      record = Object.new
      raising_stub = ->(*_args) { raise Pundit::NotAuthorizedError }

      op_class = Class.new(Operations::Base) do
        define_method(:policy_check) { authorize(record, :show?) }
        define_method(:perform) { :unreached }
      end

      Pundit.stub(:authorize, raising_stub) do
        assert_raises(Pundit::NotAuthorizedError) do
          op_class.call(context: build_context, params: {})
        end
      end
    end
  end
end
