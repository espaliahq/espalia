# frozen_string_literal: true

require "test_helper"

# RemoveCapabilityRoleBinding un-scopes a capability from a role
# (shape-changing: auto-opens a draft). The removal is deferred from the
# published read model until publish.
class Operations::Frameworks::RemoveCapabilityRoleBindingTest < ActiveSupport::TestCase
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

  def remove(ctx, params)
    Operations::Frameworks::RemoveCapabilityRoleBinding.call(context: ctx, params: params)
  end

  context "as a tenant admin" do
    should "remove the binding, auto-open a draft, and apply on publish" do
      ActsAsTenant.with_tenant(@tenant) do
        result = remove(@admin_ctx, { framework_id: @framework_id, binding_id: @binding_id })

        assert result[:removed]
        assert_equal @cap_id, result[:capability_id]
        assert_equal @role_id, result[:role_id]
        assert framework.draft_in_progress

        # Shape-changing — still present in the read model until publish.
        assert FrameworkState::CapabilityRoleBinding.exists?(binding_id: @binding_id)

        Frameworks::CommandHandler.new.publish_version(@framework_id, "seed")

        assert_not FrameworkState::CapabilityRoleBinding.exists?(binding_id: @binding_id)
      end
    end

    should "raise when the binding is not in this framework" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(ActiveRecord::RecordNotFound) do
          remove(@admin_ctx, { framework_id: @framework_id, binding_id: SecureRandom.uuid_v7 })
        end
      end
    end
  end

  context "as a tenant member (no edit rights)" do
    should "be denied" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Pundit::NotAuthorizedError) do
          remove(@member_ctx, { framework_id: @framework_id, binding_id: @binding_id })
        end
      end
    end
  end
end
