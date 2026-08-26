# frozen_string_literal: true

require "test_helper"

# UpdateCapabilityRoleBinding re-tunes a binding's weight / individual tolerance.
# Shape-preserving — applies live (no draft), so the read model reflects the
# change immediately.
class Operations::Frameworks::UpdateCapabilityRoleBindingTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user)
    @member_user = create(:user)

    ActsAsTenant.with_tenant(@tenant) do
      @admin_tu = create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      @member_tu = create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)

      @framework_id = SecureRandom.uuid_v7
      @cat_id = SecureRandom.uuid_v7
      @role_id = SecureRandom.uuid_v7
      @cap_id = SecureRandom.uuid_v7
      @binding_id = SecureRandom.uuid_v7
      handler = Frameworks::CommandHandler.new
      handler.create_framework(@framework_id, "Eng")
      rfid = SecureRandom.uuid_v7
      handler.add_role_family(@framework_id, rfid, "Engineering")
      handler.add_role(@framework_id, @role_id, rfid, "Software Engineer", "E", "ic")
      handler.add_capability_category(@framework_id, @cat_id, "Thinking")
      handler.add_capability(@framework_id, @cap_id, SecureRandom.uuid_v7, @cat_id, "Critical Thinking")
      handler.create_capability_role_binding(@framework_id, @binding_id, @cap_id, @role_id, weight: 1.0)
      handler.publish_version(@framework_id, "seed")
    end

    @admin_ctx = AuthorizationContext.new(user: @admin_user, tenant_user: @admin_tu, person: nil)
    @member_ctx = AuthorizationContext.new(user: @member_user, tenant_user: @member_tu, person: nil)
  end

  def framework
    FrameworkState::Framework.find_by!(framework_id: @framework_id)
  end

  def the_binding
    FrameworkState::CapabilityRoleBinding.find_by!(binding_id: @binding_id)
  end

  def update(ctx, params)
    Operations::Frameworks::UpdateCapabilityRoleBinding.call(context: ctx, params: params)
  end

  context "as a tenant admin" do
    should "update the weight and apply live (no draft)" do
      ActsAsTenant.with_tenant(@tenant) do
        result = update(@admin_ctx, { framework_id: @framework_id, binding_id: @binding_id, weight: 2.5 })

        assert_equal @cap_id, result[:capability_id]
        assert_equal @role_id, result[:role_id]
        assert_in_delta 2.5, result[:weight].to_f, 0.001
        assert_in_delta 2.5, the_binding.weight.to_f, 0.001
        assert_not framework.draft_in_progress, "weight tweak is shape-preserving — no draft"
      end
    end

    should "update individual_tolerance into the read model's deficit_threshold" do
      ActsAsTenant.with_tenant(@tenant) do
        update(@admin_ctx, { framework_id: @framework_id, binding_id: @binding_id, individual_tolerance: 0 })

        assert_equal 0, the_binding.deficit_threshold.to_i
      end
    end

    should "accept an integer weight (JSON-RPC may send 3 not 3.0)" do
      ActsAsTenant.with_tenant(@tenant) do
        result = update(@admin_ctx, { framework_id: @framework_id, binding_id: @binding_id, weight: 3 })

        assert_in_delta 3.0, the_binding.weight.to_f, 0.001
        assert_in_delta 3.0, result[:weight].to_f, 0.001
      end
    end

    should "reject an update with no changes" do
      ActsAsTenant.with_tenant(@tenant) do
        error = assert_raises(Operations::Base::ParameterError) do
          update(@admin_ctx, { framework_id: @framework_id, binding_id: @binding_id })
        end
        assert_match(/at least one of: weight, individual_tolerance/i, error.message)
      end
    end

    should "reject a non-positive weight" do
      ActsAsTenant.with_tenant(@tenant) do
        error = assert_raises(Operations::Base::ParameterError) do
          update(@admin_ctx, { framework_id: @framework_id, binding_id: @binding_id, weight: 0 })
        end
        assert_match(/weight must be greater than 0/i, error.message)
      end
    end

    should "reject a negative individual_tolerance" do
      ActsAsTenant.with_tenant(@tenant) do
        error = assert_raises(Operations::Base::ParameterError) do
          update(@admin_ctx, { framework_id: @framework_id, binding_id: @binding_id, individual_tolerance: -1 })
        end
        assert_match(/0 or greater/i, error.message)
      end
    end

    should "raise when the binding is not in this framework" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(ActiveRecord::RecordNotFound) do
          update(@admin_ctx, { framework_id: @framework_id, binding_id: SecureRandom.uuid_v7, weight: 2.0 })
        end
      end
    end
  end

  context "as a tenant member (no edit rights)" do
    should "be denied" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Pundit::NotAuthorizedError) do
          update(@member_ctx, { framework_id: @framework_id, binding_id: @binding_id, weight: 2.0 })
        end
      end
    end
  end
end
