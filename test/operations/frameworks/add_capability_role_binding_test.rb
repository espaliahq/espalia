# frozen_string_literal: true

require "test_helper"

# AddCapabilityRoleBinding binds a capability to a role (shape-changing:
# auto-opens a draft). The new binding is deferred from the published read
# model until publish.
class Operations::Frameworks::AddCapabilityRoleBindingTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user)
    @member_user = create(:user)

    ActsAsTenant.with_tenant(@tenant) do
      @admin_tu = create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      @member_tu = create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)

      @framework_id = SecureRandom.uuid_v7
      @cat_id = SecureRandom.uuid_v7
      @role_a = SecureRandom.uuid_v7
      @role_b = SecureRandom.uuid_v7
      @cap_id = SecureRandom.uuid_v7
      handler = Frameworks::CommandHandler.new
      handler.create_framework(@framework_id, "Eng")
      rfid = SecureRandom.uuid_v7
      handler.add_role_family(@framework_id, rfid, "Engineering")
      handler.add_role(@framework_id, @role_a, rfid, "Software Engineer", "E", "ic")
      handler.add_role(@framework_id, @role_b, rfid, "Engineering Manager", "EM", "management")
      handler.add_capability_category(@framework_id, @cat_id, "Thinking")
      handler.add_capability(@framework_id, @cap_id, SecureRandom.uuid_v7, @cat_id, "Critical Thinking")
      handler.create_capability_role_binding(@framework_id, SecureRandom.uuid_v7, @cap_id, @role_a, weight: 1.0)
      handler.publish_version(@framework_id, "seed")
    end

    @admin_ctx = AuthorizationContext.new(user: @admin_user, tenant_user: @admin_tu, person: nil)
    @member_ctx = AuthorizationContext.new(user: @member_user, tenant_user: @member_tu, person: nil)
  end

  def framework
    FrameworkState::Framework.find_by!(framework_id: @framework_id)
  end

  def add(ctx, params)
    Operations::Frameworks::AddCapabilityRoleBinding.call(context: ctx, params: params)
  end

  context "as a tenant admin" do
    should "bind to a new role, auto-open a draft, and apply on publish" do
      ActsAsTenant.with_tenant(@tenant) do
        result = add(@admin_ctx, {
          framework_id: @framework_id, capability_id: @cap_id, role_id: @role_b, weight: 2.0
        })

        assert_equal @cap_id, result[:capability_id]
        assert_equal @role_b, result[:role_id]
        assert framework.draft_in_progress

        # Shape-changing — deferred until publish.
        assert_not FrameworkState::CapabilityRoleBinding.exists?(capability_id: @cap_id, role_id: @role_b)

        Frameworks::CommandHandler.new.publish_version(@framework_id, "seed")

        binding = FrameworkState::CapabilityRoleBinding.find_by(capability_id: @cap_id, role_id: @role_b)
        assert_not_nil binding
        assert_in_delta 2.0, binding.weight.to_f, 0.001
      end
    end

    should "default the weight to 1.0 when omitted" do
      ActsAsTenant.with_tenant(@tenant) do
        add(@admin_ctx, { framework_id: @framework_id, capability_id: @cap_id, role_id: @role_b })
        Frameworks::CommandHandler.new.publish_version(@framework_id, "seed")

        binding = FrameworkState::CapabilityRoleBinding.find_by(capability_id: @cap_id, role_id: @role_b)
        assert_in_delta 1.0, binding.weight.to_f, 0.001
      end
    end

    should "reject binding to a role already bound" do
      ActsAsTenant.with_tenant(@tenant) do
        error = assert_raises(Operations::Base::ParameterError) do
          add(@admin_ctx, { framework_id: @framework_id, capability_id: @cap_id, role_id: @role_a })
        end
        assert_match(/already bound/i, error.message)
        assert_not framework.draft_in_progress
      end
    end

    should "reject an unknown role" do
      ActsAsTenant.with_tenant(@tenant) do
        error = assert_raises(Operations::Base::ParameterError) do
          add(@admin_ctx, { framework_id: @framework_id, capability_id: @cap_id, role_id: SecureRandom.uuid_v7 })
        end
        assert_match(/unknown role/i, error.message)
        assert_not framework.draft_in_progress
      end
    end

    should "reject a non-positive weight" do
      ActsAsTenant.with_tenant(@tenant) do
        error = assert_raises(Operations::Base::ParameterError) do
          add(@admin_ctx, { framework_id: @framework_id, capability_id: @cap_id, role_id: @role_b, weight: 0 })
        end
        assert_match(/weight must be greater than 0/i, error.message)
      end
    end

    should "raise when the capability is not in this framework" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(ActiveRecord::RecordNotFound) do
          add(@admin_ctx, { framework_id: @framework_id, capability_id: SecureRandom.uuid_v7, role_id: @role_b })
        end
      end
    end
  end

  context "as a tenant member (no edit rights)" do
    should "be denied" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Pundit::NotAuthorizedError) do
          add(@member_ctx, { framework_id: @framework_id, capability_id: @cap_id, role_id: @role_b })
        end
      end
    end
  end
end
