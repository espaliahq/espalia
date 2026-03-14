# frozen_string_literal: true

require "test_helper"

class TenantUserTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @user = create(:user)
  end

  subject { ActsAsTenant.with_tenant(@tenant) { build(:tenant_user, tenant: @tenant, user: @user) } }

  context "associations" do
    should belong_to(:tenant)
    should belong_to(:user)
    should belong_to(:person).optional
  end

  context "validations" do
    should validate_presence_of(:role)
  end

  context "role enum" do
    should "default to member" do
      ActsAsTenant.with_tenant(@tenant) do
        tenant_user = create(:tenant_user, tenant: @tenant, user: @user)
        assert tenant_user.member?
      end
    end

    should "accept admin role" do
      ActsAsTenant.with_tenant(@tenant) do
        tenant_user = build(:tenant_user, tenant: @tenant, user: @user, role: :admin)
        assert tenant_user.valid?
        assert tenant_user.admin?
      end
    end
  end

  context "uniqueness" do
    should "prevent duplicate user within a tenant" do
      ActsAsTenant.with_tenant(@tenant) do
        create(:tenant_user, tenant: @tenant, user: @user)
        duplicate = build(:tenant_user, tenant: @tenant, user: @user)
        assert_not duplicate.valid?
      end
    end

    should "allow same user in different tenants" do
      other_tenant = create(:tenant)
      ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, user: @user) }
      ActsAsTenant.with_tenant(other_tenant) do
        other_membership = build(:tenant_user, tenant: other_tenant, user: @user)
        assert other_membership.valid?
      end
    end
  end
end
