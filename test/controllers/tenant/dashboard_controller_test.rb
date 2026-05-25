# frozen_string_literal: true

require "test_helper"

class Tenant::DashboardControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    @admin_user  = create(:user, password: "password123")
    @member_user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)
    end
  end

  context "as a tenant admin" do
    setup { sign_in @admin_user }

    should "render the dashboard with section tiles" do
      get tenant_root_path
      assert_response :success
      assert_includes response.body, "Tenant administration"
      assert_includes response.body, "Theme"
      assert_includes response.body, "Users"
      assert_includes response.body, "Integrations"
    end
  end

  context "as a tenant member" do
    setup { sign_in @member_user }

    should "redirect with an authorization alert" do
      get tenant_root_path
      assert_response :redirect
      follow_redirect!
      assert_includes flash[:alert], "not authorized"
    end
  end

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end
