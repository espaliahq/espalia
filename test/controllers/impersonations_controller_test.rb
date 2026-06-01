# frozen_string_literal: true

require "test_helper"

class ImpersonationsControllerTest < ActionDispatch::IntegrationTest
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

    context "POST /impersonation" do
      should "start impersonating a member and redirect home" do
        post impersonation_path, params: { tenant_user_id: @member_tu.id }
        assert_redirected_to root_path
        assert_match(/viewing as/i, flash[:notice])
      end

      should "switch the effective context to the target (admin surfaces now denied)" do
        post impersonation_path, params: { tenant_user_id: @member_tu.id }
        # While impersonating a member, the admin-only user list is no longer
        # authorised — proof the identity chain was overridden.
        get tenant_users_path
        assert_redirected_to root_path
      end

      should "refuse to impersonate another admin and leave context intact" do
        other_admin = ActsAsTenant.with_tenant(@tenant) do
          create(:tenant_user, tenant: @tenant, user: create(:user), role: :admin)
        end
        post impersonation_path, params: { tenant_user_id: other_admin.id }
        assert_redirected_to root_path
        # Not impersonating — admin list still reachable.
        get tenant_users_path
        assert_response :success
      end

      should "block state-changing requests while impersonating (read-only)" do
        post impersonation_path, params: { tenant_user_id: @member_tu.id }
        patch tenant_user_path(@member_tu), params: { tenant_user: { role: "admin" } }
        assert_redirected_to root_path
        assert_match(/read-only/, flash[:alert])
        assert_equal "member", @member_tu.reload.role
      end

      should "expire the session after the TTL" do
        post impersonation_path, params: { tenant_user_id: @member_tu.id }
        travel(Impersonatable::TTL + 1.minute) do
          # Session expired → reverts to the real admin, who can see the list.
          get tenant_users_path
          assert_response :success
        end
      end
    end

    context "DELETE /impersonation" do
      should "stop impersonating" do
        post impersonation_path, params: { tenant_user_id: @member_tu.id }
        delete impersonation_path
        assert_redirected_to root_path
        # Real admin restored.
        get tenant_users_path
        assert_response :success
      end
    end
  end

  context "as a tenant member" do
    setup { sign_in @member_user }

    should "deny starting impersonation" do
      post impersonation_path, params: { tenant_user_id: @admin_tu.id }
      assert_redirected_to root_path
      get assessments_path # any authenticated page; member is not impersonating
      assert_response :success
    end
  end

  context "unauthenticated" do
    should "redirect to sign in" do
      post impersonation_path, params: { tenant_user_id: @member_tu.id }
      assert_redirected_to new_user_session_path
    end
  end

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end
