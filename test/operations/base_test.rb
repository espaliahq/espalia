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

    should "forward authorize to Pundit with the context" do
      record = Object.new
      seen = nil
      authorize_stub = lambda do |user, rec, query|
        seen = { user: user, record: rec, query: query }
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
