# frozen_string_literal: true

require "test_helper"

# RenameDepartment relabels a department across every role family carrying it.
# Shape-preserving — applies live, opens no draft.
class Operations::Frameworks::RenameDepartmentTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user)
    @member_user = create(:user)

    ActsAsTenant.with_tenant(@tenant) do
      @admin_tu = create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      @member_tu = create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)

      @framework_id = SecureRandom.uuid_v7
      @fc_id = SecureRandom.uuid_v7
      @fo_id = SecureRandom.uuid_v7
      @eng_id = SecureRandom.uuid_v7
      handler = Frameworks::CommandHandler.new
      handler.create_framework(@framework_id, "Org")
      handler.add_role_family(@framework_id, @fc_id, "Financial Control", department: "Finance")
      handler.add_role_family(@framework_id, @fo_id, "Finance Operations", department: "Finance")
      handler.add_role_family(@framework_id, @eng_id, "Engineering", department: "Product + Engineering")
      handler.publish_version(@framework_id, "seed")
    end

    @admin_ctx = AuthorizationContext.new(user: @admin_user, tenant_user: @admin_tu, person: nil)
    @member_ctx = AuthorizationContext.new(user: @member_user, tenant_user: @member_tu, person: nil)
  end

  def department_of(role_family_id)
    FrameworkState::RoleFamily.find_by(role_family_id: role_family_id).department
  end

  def framework
    FrameworkState::Framework.find_by!(framework_id: @framework_id)
  end

  context "as a tenant admin" do
    should "relabel every family in the department and leave others untouched" do
      ActsAsTenant.with_tenant(@tenant) do
        result = Operations::Frameworks::RenameDepartment.call(
          context: @admin_ctx,
          params: { framework_id: @framework_id, from: "Finance", to: "Commercial Finance" }
        )

        assert_equal 2, result[:renamed_count]
        assert_equal "Commercial Finance", department_of(@fc_id)
        assert_equal "Commercial Finance", department_of(@fo_id)
        assert_equal "Product + Engineering", department_of(@eng_id)
        assert_not framework.draft_in_progress
      end
    end

    should "ungroup the families when renamed to blank" do
      ActsAsTenant.with_tenant(@tenant) do
        Operations::Frameworks::RenameDepartment.call(
          context: @admin_ctx,
          params: { framework_id: @framework_id, from: "Finance", to: "" }
        )

        assert_nil department_of(@fc_id)
        assert_nil department_of(@fo_id)
      end
    end

    should "raise when from is blank" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Operations::Base::ParameterError) do
          Operations::Frameworks::RenameDepartment.call(
            context: @admin_ctx, params: { framework_id: @framework_id, from: "", to: "X" }
          )
        end
      end
    end

    should "raise when the target equals the source" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Operations::Base::ParameterError) do
          Operations::Frameworks::RenameDepartment.call(
            context: @admin_ctx, params: { framework_id: @framework_id, from: "Finance", to: "Finance" }
          )
        end
      end
    end

    should "be a no-op when no family carries the department" do
      ActsAsTenant.with_tenant(@tenant) do
        result = Operations::Frameworks::RenameDepartment.call(
          context: @admin_ctx,
          params: { framework_id: @framework_id, from: "Nonexistent", to: "Whatever" }
        )
        assert_equal 0, result[:renamed_count]
      end
    end
  end

  context "as a plain tenant member" do
    should "be denied" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Pundit::NotAuthorizedError) do
          Operations::Frameworks::RenameDepartment.call(
            context: @member_ctx,
            params: { framework_id: @framework_id, from: "Finance", to: "Nope" }
          )
        end
      end
    end
  end
end
