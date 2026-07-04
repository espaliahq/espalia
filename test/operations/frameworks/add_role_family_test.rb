# frozen_string_literal: true

require "test_helper"

# AddRoleFamily creates a grouping container for roles. Shape-preserving —
# applies to the published read model immediately and opens no draft.
class Operations::Frameworks::AddRoleFamilyTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user)
    @member_user = create(:user)

    ActsAsTenant.with_tenant(@tenant) do
      @admin_tu = create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      @member_tu = create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)

      @framework_id = SecureRandom.uuid_v7
      handler = Frameworks::CommandHandler.new
      handler.create_framework(@framework_id, "Eng")
      handler.publish_version(@framework_id, "seed")
    end

    @admin_ctx = AuthorizationContext.new(user: @admin_user, tenant_user: @admin_tu, person: nil)
    @member_ctx = AuthorizationContext.new(user: @member_user, tenant_user: @member_tu, person: nil)
  end

  def framework
    FrameworkState::Framework.find_by!(framework_id: @framework_id)
  end

  context "as a tenant admin" do
    should "add the role family live without opening a draft" do
      ActsAsTenant.with_tenant(@tenant) do
        result = Operations::Frameworks::AddRoleFamily.call(
          context: @admin_ctx,
          params: { framework_id: @framework_id, name: "Design", department: "Product + Design" }
        )

        family = FrameworkState::RoleFamily.find_by(
          framework_id: @framework_id, role_family_id: result[:role_family_id]
        )
        assert_equal "Design", family.name
        assert_equal "Product + Design", family.department
        assert_not framework.draft_in_progress
      end
    end

    should "treat a blank department as ungrouped" do
      ActsAsTenant.with_tenant(@tenant) do
        result = Operations::Frameworks::AddRoleFamily.call(
          context: @admin_ctx,
          params: { framework_id: @framework_id, name: "Design", department: "" }
        )

        family = FrameworkState::RoleFamily.find_by(
          framework_id: @framework_id, role_family_id: result[:role_family_id]
        )
        assert_nil family.department
        assert_nil result[:department]
      end
    end
  end

  context "as a plain tenant member" do
    should "be denied" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Pundit::NotAuthorizedError) do
          Operations::Frameworks::AddRoleFamily.call(
            context: @member_ctx, params: { framework_id: @framework_id, name: "Nope" }
          )
        end
      end
    end
  end
end
