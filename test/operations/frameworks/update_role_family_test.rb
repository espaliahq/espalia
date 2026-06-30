# frozen_string_literal: true

require "test_helper"

# UpdateRoleFamily renames / re-describes a role family. Shape-preserving —
# applies to the published read model immediately and opens no draft.
class Operations::Frameworks::UpdateRoleFamilyTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user)
    @member_user = create(:user)

    ActsAsTenant.with_tenant(@tenant) do
      @admin_tu = create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      @member_tu = create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)

      @framework_id = SecureRandom.uuid_v7
      @rf_id = SecureRandom.uuid_v7
      handler = Frameworks::CommandHandler.new
      handler.create_framework(@framework_id, "Eng")
      handler.add_role_family(@framework_id, @rf_id, "Engineering", description: "Builds things")
      handler.publish_version(@framework_id, "seed")
    end

    @admin_ctx = AuthorizationContext.new(user: @admin_user, tenant_user: @admin_tu, person: nil)
    @member_ctx = AuthorizationContext.new(user: @member_user, tenant_user: @member_tu, person: nil)
  end

  def framework
    FrameworkState::Framework.find_by!(framework_id: @framework_id)
  end

  def role_family
    FrameworkState::RoleFamily.find_by(framework_id: @framework_id, role_family_id: @rf_id)
  end

  context "as a tenant admin" do
    should "rename the role family live without opening a draft" do
      ActsAsTenant.with_tenant(@tenant) do
        result = Operations::Frameworks::UpdateRoleFamily.call(
          context: @admin_ctx,
          params: { framework_id: @framework_id, role_family_id: @rf_id, name: "Platform Engineering" }
        )

        assert_equal "Platform Engineering", result[:name]
        assert_equal "Platform Engineering", role_family.name
        assert_not framework.draft_in_progress
      end
    end

    should "raise when no updatable field is supplied" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Operations::Base::ParameterError) do
          Operations::Frameworks::UpdateRoleFamily.call(
            context: @admin_ctx, params: { framework_id: @framework_id, role_family_id: @rf_id }
          )
        end
      end
    end

    should "move the role family into a department live" do
      ActsAsTenant.with_tenant(@tenant) do
        result = Operations::Frameworks::UpdateRoleFamily.call(
          context: @admin_ctx,
          params: { framework_id: @framework_id, role_family_id: @rf_id, department: "Product + Engineering" }
        )

        assert_equal "Product + Engineering", result[:department]
        assert_equal "Product + Engineering", role_family.department
        assert_not framework.draft_in_progress
      end
    end

    should "clear the department when given a blank string" do
      ActsAsTenant.with_tenant(@tenant) do
        Operations::Frameworks::UpdateRoleFamily.call(
          context: @admin_ctx,
          params: { framework_id: @framework_id, role_family_id: @rf_id, department: "Finance" }
        )
        Operations::Frameworks::UpdateRoleFamily.call(
          context: @admin_ctx,
          params: { framework_id: @framework_id, role_family_id: @rf_id, department: "" }
        )

        assert_nil role_family.department
      end
    end

    should "treat department as a supplied field on its own" do
      ActsAsTenant.with_tenant(@tenant) do
        # department-only (no name) must not raise the "nothing to update" error
        assert_nothing_raised do
          Operations::Frameworks::UpdateRoleFamily.call(
            context: @admin_ctx,
            params: { framework_id: @framework_id, role_family_id: @rf_id, department: "Ops" }
          )
        end
      end
    end
  end

  context "as a plain tenant member" do
    should "be denied" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Pundit::NotAuthorizedError) do
          Operations::Frameworks::UpdateRoleFamily.call(
            context: @member_ctx,
            params: { framework_id: @framework_id, role_family_id: @rf_id, name: "Nope" }
          )
        end
      end
    end
  end
end
