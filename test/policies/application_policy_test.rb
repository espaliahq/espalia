# frozen_string_literal: true

require "test_helper"

class ApplicationPolicyTest < ActiveSupport::TestCase
  context "#tenant_admin?" do
    should "return true for global admin" do
      user = build(:user, global_admin: true)
      ctx = AuthorizationContext.new(user: user, tenant_user: nil, person: nil)

      assert ApplicationPolicy.new(ctx, nil).send(:tenant_admin?)
    end

    should "return true for tenant admin" do
      user = build(:user)
      tenant_user = build(:tenant_user, user: user, role: :admin)
      ctx = AuthorizationContext.new(user: user, tenant_user: tenant_user, person: nil)

      assert ApplicationPolicy.new(ctx, nil).send(:tenant_admin?)
    end

    should "return false for tenant member" do
      user = build(:user)
      tenant_user = build(:tenant_user, user: user, role: :member)
      ctx = AuthorizationContext.new(user: user, tenant_user: tenant_user, person: nil)

      assert_not ApplicationPolicy.new(ctx, nil).send(:tenant_admin?)
    end

    should "return false when no tenant_user" do
      user = build(:user)
      ctx = AuthorizationContext.new(user: user, tenant_user: nil, person: nil)

      assert_not ApplicationPolicy.new(ctx, nil).send(:tenant_admin?)
    end
  end

  context "#tenant_member?" do
    should "return true when tenant_user present" do
      tenant_user = build(:tenant_user)
      ctx = AuthorizationContext.new(user: tenant_user.user, tenant_user: tenant_user, person: nil)

      assert ApplicationPolicy.new(ctx, nil).send(:tenant_member?)
    end

    should "return false when tenant_user nil" do
      ctx = AuthorizationContext.new(user: build(:user), tenant_user: nil, person: nil)

      assert_not ApplicationPolicy.new(ctx, nil).send(:tenant_member?)
    end
  end

  context "default deny" do
    should "deny all actions by default" do
      ctx = AuthorizationContext.new(user: build(:user), tenant_user: nil, person: nil)
      policy = ApplicationPolicy.new(ctx, nil)

      assert_not policy.index?
      assert_not policy.show?
      assert_not policy.create?
      assert_not policy.update?
      assert_not policy.destroy?
    end
  end
end
