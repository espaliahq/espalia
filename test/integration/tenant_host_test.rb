# frozen_string_literal: true

require "test_helper"

# A tenant's custom domain (#660): a request arriving on it assumes the
# tenant — the sign-in page carries its branding pre-auth, and a signed-in
# member is pinned to it whatever their session said.
class TenantHostTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @tenant = create(:tenant, name: "Null Island Systems", slug: "nullisland",
      custom_domain: "growth.nullisland.example", product_name: "Ladder",
      theme: "custom", custom_theme: { "brand" => { "light" => "#aa3366", "dark" => "#bb4477" } })
    @user = create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, user: @user) }
  end

  context "the sign-in page on a custom domain" do
    should "carry the tenant's name, product name and theme without any slug" do
      host! "growth.nullisland.example"
      get new_user_session_path

      assert_response :success
      assert_includes response.body, ">Null Island Systems</h1>"
      assert_includes response.body, "Ladder · Career growth for your team"
      assert_includes response.body, "--tenant-brand:#aa3366"
    end

    should "scope the session to the tenant when a member signs in" do
      host! "growth.nullisland.example"
      post user_session_path, params: { user: { email: @user.email, password: "password123" } }

      assert_redirected_to root_path
      assert_equal @tenant.id, session[:current_tenant_id]
    end
  end

  context "a signed-in member on a custom domain" do
    should "be pinned to the domain's tenant over the session's" do
      other = create(:tenant, name: "Driftwood")
      ActsAsTenant.with_tenant(other) { create(:tenant_user, tenant: other, user: @user) }
      sign_in @user

      get root_path
      # Plain host resolves from the session: first tenant wins, whichever it is.
      assert_response :success

      host! "growth.nullisland.example"
      get root_path

      assert_response :success
      assert_includes response.body, "Null Island Systems Ladder"
      assert_equal @tenant.id, session[:current_tenant_id]
    end
  end

  context "a signed-in non-member on a custom domain" do
    should "fall back to their own tenant" do
      outsider_tenant = create(:tenant, name: "Elsewhere Org")
      outsider = create(:user, password: "password123")
      ActsAsTenant.with_tenant(outsider_tenant) { create(:tenant_user, tenant: outsider_tenant, user: outsider) }
      sign_in outsider

      host! "growth.nullisland.example"
      get root_path

      assert_response :success
      assert_includes response.body, "Elsewhere Org"
      assert_equal outsider_tenant.id, session[:current_tenant_id]
    end
  end
end
