# frozen_string_literal: true

require "test_helper"

class DefaultAccountRoutesTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  context "self sign-up" do
    should "create a signed-in account that belongs to no tenant and holds no admin flag" do
      assert_difference -> { User.count }, 1 do
        post "/users", params: { user: { email: "new@example.com", password: "password123", password_confirmation: "password123" } }
      end

      user = User.find_by!(email: "new@example.com")
      assert_not user.global_admin?
      assert_empty ActsAsTenant.without_tenant { TenantUser.unscoped.where(user:) }
      assert_redirected_to root_path
    end
  end

  context "edit account" do
    should "change the password, given the current one" do
      user = create(:user)
      sign_in user

      patch "/users", params: { user: { password: "changed12345", password_confirmation: "changed12345", current_password: "password123" } }

      assert user.reload.valid_password?("changed12345")
    end
  end

  context "delete account" do
    should "delete the account and its memberships, and leave the tenant's people" do
      tenant_user = create(:tenant_user)
      person = ActsAsTenant.with_tenant(tenant_user.tenant) { create(:person, tenant: tenant_user.tenant) }
      sign_in tenant_user.user

      delete "/users"

      assert_not User.exists?(tenant_user.user_id)
      assert_not TenantUser.unscoped.exists?(tenant_user.id)
      assert Person.unscoped.exists?(person.id)
    end
  end
end
