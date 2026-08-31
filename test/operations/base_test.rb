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
      assert_match(/outside its allowed set/, err.message)
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
