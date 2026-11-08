# frozen_string_literal: true

require "test_helper"

# A single-org instance's default tenant (DEFAULT_TENANT_SLUG,
# https://github.com/espaliahq/espalia/issues/12): the instance's own sign-in
# brands as that tenant and scopes a member's session to it, while explicit
# sign-on URLs, custom domains and signed-in sessions behave as without it.
class DefaultTenantSignOnTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @tenant = create(:tenant, name: "Null Island Systems", slug: "nullisland",
      product_name: "Ladder")
    @user = create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, user: @user) }
    Rails.application.config.x.default_tenant_slug = "nullisland"
  end

  teardown do
    Rails.application.config.x.default_tenant_slug = nil
  end

  context "the instance sign-in page with a default tenant" do
    should "carry the tenant's branding without any slug in the URL" do
      get new_user_session_path

      assert_response :success
      assert_includes response.body, ">Null Island Systems</h1>"
      assert_includes response.body, "Ladder · Career growth for your team"
    end

    should "scope the session to the default tenant when a member signs in" do
      post user_session_path, params: { user: { email: @user.email, password: "password123" } }

      assert_redirected_to root_path
      assert_equal @tenant.id, session[:current_tenant_id]
    end

    should "leave a non-member's resolution alone" do
      outsider_tenant = create(:tenant, name: "Elsewhere Org")
      outsider = create(:user, password: "password123")
      ActsAsTenant.with_tenant(outsider_tenant) { create(:tenant_user, tenant: outsider_tenant, user: outsider) }

      post user_session_path, params: { user: { email: outsider.email, password: "password123" } }

      assert_redirected_to root_path
      assert_equal outsider_tenant.id, session[:current_tenant_id]
    end
  end

  context "surfaces the default tenant must not touch" do
    should "lose to an explicit tenant sign-on URL" do
      other = create(:tenant, name: "Driftwood", slug: "driftwood", product_name: "Rings")

      get tenant_sign_in_path(tenant_slug: "driftwood")

      assert_response :success
      assert_includes response.body, ">Driftwood</h1>"
      assert_includes response.body, "Rings · Career growth for your team"
      assert_not_includes response.body, "Null Island Systems"
    end

    should "lose to a custom domain" do
      create(:tenant, name: "Harbour Co", slug: "harbour",
        custom_domain: "growth.harbour.example", product_name: "Tides")

      host! "growth.harbour.example"
      get new_user_session_path

      assert_response :success
      assert_includes response.body, ">Harbour Co</h1>"
      assert_not_includes response.body, "Null Island Systems"
    end

    should "still redirect a mistyped slug instead of wearing the default's branding" do
      get tenant_sign_in_path(tenant_slug: "no-such-org")

      assert_redirected_to new_user_session_path
    end

    should "not force a signed-in member off the tenant they switched to" do
      other = create(:tenant, name: "Driftwood")
      ActsAsTenant.with_tenant(other) { create(:tenant_user, tenant: other, user: @user) }

      post user_session_path, params: { user: { email: @user.email, password: "password123" } }
      post users_tenant_switch_path, params: { tenant_id: other.id }
      get root_path

      assert_response :success
      assert_equal other.id, session[:current_tenant_id]
    end
  end

  context "a slug naming no tenant" do
    should "degrade to the instance sign-in, never an error" do
      Rails.application.config.x.default_tenant_slug = "no-such-org"

      get new_user_session_path

      assert_response :success
      assert_not_includes response.body, "Null Island Systems"
    end
  end
end
