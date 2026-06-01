# frozen_string_literal: true

require "test_helper"

class ImpersonationPolicyTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @member_user = create(:user)
    @member_tu = create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)
  end

  teardown { ActsAsTenant.current_tenant = nil }

  # Build a context for an acting admin and policy targeting +record+.
  def policy_for(context, record = @member_tu)
    ImpersonationPolicy.new(context, record)
  end

  context "as a tenant admin" do
    setup do
      @admin_user = create(:user)
      @admin_tu = create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      @ctx = AuthorizationContext.new(user: @admin_user, tenant_user: @admin_tu, person: nil)
    end

    should "permit impersonating a non-admin member" do
      assert policy_for(@ctx).create?
    end

    should "deny impersonating another tenant admin" do
      other_admin = create(:tenant_user, tenant: @tenant, user: create(:user), role: :admin)
      assert_not policy_for(@ctx, other_admin).create?
    end

    should "deny impersonating a global admin" do
      ga = create(:tenant_user, tenant: @tenant, user: create(:user, global_admin: true), role: :member)
      assert_not policy_for(@ctx, ga).create?
    end

    should "deny impersonating oneself" do
      assert_not policy_for(@ctx, @admin_tu).create?
    end

    should "deny impersonating a member of another tenant" do
      other_tenant = create(:tenant)
      foreign_tu = ActsAsTenant.with_tenant(other_tenant) do
        create(:tenant_user, tenant: other_tenant, user: create(:user), role: :member)
      end
      assert_not policy_for(@ctx, foreign_tu).create?
    end
  end

  context "as a tenant member" do
    setup do
      actor = create(:user)
      tu = create(:tenant_user, tenant: @tenant, user: actor, role: :member)
      @ctx = AuthorizationContext.new(user: actor, tenant_user: tu, person: nil)
    end

    should "deny impersonating anyone" do
      assert_not policy_for(@ctx).create?
    end
  end

  context "with no tenant membership" do
    setup do
      @ctx = AuthorizationContext.new(user: create(:user), tenant_user: nil, person: nil)
    end

    should "deny impersonating anyone" do
      assert_not policy_for(@ctx).create?
    end
  end

  context "as a global admin" do
    setup do
      ga = create(:user, global_admin: true)
      @ctx = AuthorizationContext.new(user: ga, tenant_user: nil, person: nil)
    end

    should "permit impersonating a non-admin member in the active tenant" do
      assert policy_for(@ctx).create?
    end
  end
end
