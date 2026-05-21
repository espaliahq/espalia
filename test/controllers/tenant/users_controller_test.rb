# frozen_string_literal: true

require "test_helper"

class Tenant::UsersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    @admin_user  = create(:user, password: "password123")
    @member_user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @admin_tu  = create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      @member_tu = create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)
    end
  end

  context "as a tenant admin" do
    setup { sign_in @admin_user }

    context "GET /tenant/users" do
      should "render the tenant user index" do
        get tenant_users_path
        assert_response :success
        assert_includes response.body, "Tenant users"
        assert_includes response.body, @admin_user.email
        assert_includes response.body, @member_user.email
      end
    end

    context "GET /tenant/users/:id" do
      should "render the user detail page" do
        get tenant_user_path(@member_tu.id)
        assert_response :success
        assert_includes response.body, @member_user.email
        assert_includes response.body, "Tenant role"
        assert_includes response.body, "Framework involvement"
      end
    end

    context "PATCH /tenant/users/:id" do
      should "promote a member to admin" do
        patch tenant_user_path(@member_tu.id),
              params: { tenant_user: { role: "admin" } }
        assert_redirected_to tenant_user_path(@member_tu.id)
        assert_equal "admin", @member_tu.reload.role
      end

      should "demote an admin when another admin exists" do
        ActsAsTenant.with_tenant(@tenant) do
          create(:tenant_user, tenant: @tenant, user: create(:user), role: :admin)
        end
        patch tenant_user_path(@admin_tu.id),
              params: { tenant_user: { role: "member" } }
        assert_redirected_to tenant_user_path(@admin_tu.id)
        assert_equal "member", @admin_tu.reload.role
      end

      should "refuse to demote the last admin" do
        patch tenant_user_path(@admin_tu.id),
              params: { tenant_user: { role: "member" } }
        assert_redirected_to tenant_user_path(@admin_tu.id)
        follow_redirect!
        assert_includes response.body, "last tenant administrator"
        assert_equal "admin", @admin_tu.reload.role
      end
    end
  end

  context "as a tenant member" do
    setup { sign_in @member_user }

    should "deny GET /tenant/users" do
      get tenant_users_path
      assert_redirected_to root_path
    end

    should "deny GET /tenant/users/:id" do
      get tenant_user_path(@admin_tu.id)
      assert_redirected_to root_path
    end

    should "deny PATCH /tenant/users/:id" do
      patch tenant_user_path(@admin_tu.id),
            params: { tenant_user: { role: "member" } }
      assert_redirected_to root_path
      assert_equal "admin", @admin_tu.reload.role
    end
  end

  context "unauthenticated" do
    should "redirect to sign in" do
      get tenant_users_path
      assert_redirected_to new_user_session_path
    end
  end

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end
