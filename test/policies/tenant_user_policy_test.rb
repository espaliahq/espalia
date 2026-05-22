# frozen_string_literal: true

require "test_helper"

class TenantUserPolicyTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @target_user = create(:user)
    @target_tu = ActsAsTenant.with_tenant(@tenant) do
      create(:tenant_user, tenant: @tenant, user: @target_user, role: :member)
    end
  end

  context "with no tenant membership" do
    setup do
      @user = create(:user)
      @ctx = AuthorizationContext.new(user: @user, tenant_user: nil, person: nil)
    end

    should "deny everything" do
      assert_not policy.index?
      assert_not policy.show?
      assert_not policy.update?
      assert_not policy.manage_collaborators?
      assert_not policy.collaborator_scope_picker?
    end
  end

  context "as a tenant member" do
    setup do
      @user = create(:user)
      @tu = ActsAsTenant.with_tenant(@tenant) do
        create(:tenant_user, tenant: @tenant, user: @user, role: :member)
      end
      @ctx = AuthorizationContext.new(user: @user, tenant_user: @tu, person: nil)
    end

    should "deny everything" do
      assert_not policy.index?
      assert_not policy.show?
      assert_not policy.update?
      assert_not policy.manage_collaborators?
      assert_not policy.collaborator_scope_picker?
    end
  end

  context "as a tenant admin" do
    setup do
      @user = create(:user)
      @tu = ActsAsTenant.with_tenant(@tenant) do
        create(:tenant_user, tenant: @tenant, user: @user, role: :admin)
      end
      @ctx = AuthorizationContext.new(user: @user, tenant_user: @tu, person: nil)
    end

    should "permit everything" do
      assert policy.index?
      assert policy.show?
      assert policy.update?
      assert policy.manage_collaborators?
      assert policy.collaborator_scope_picker?
    end
  end

  context "as a global admin with no tenant_user" do
    setup do
      @user = create(:user, global_admin: true)
      @ctx = AuthorizationContext.new(user: @user, tenant_user: nil, person: nil)
    end

    should "permit everything" do
      assert policy.index?
      assert policy.show?
      assert policy.update?
      assert policy.manage_collaborators?
      assert policy.collaborator_scope_picker?
    end
  end

  private

  def policy
    TenantUserPolicy.new(@ctx, @target_tu)
  end
end
