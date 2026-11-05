# frozen_string_literal: true

require "test_helper"

class Users::SessionsControllerTest < ActionDispatch::IntegrationTest
  def with_google_sso(available)
    was = Rails.configuration.x.google_sso_available
    Rails.configuration.x.google_sso_available = available
    yield
  ensure
    Rails.configuration.x.google_sso_available = was
  end

  context "the sign-in page" do
    should "offer Google while the instance has it (or outside production)" do
      with_google_sso(true) do
        get new_user_session_path
      end

      assert_response :success
      assert_includes response.body, "Continue with Google"
    end

    should "offer only email and password when the instance has no Google SSO" do
      with_google_sso(false) do
        get new_user_session_path
      end

      assert_response :success
      assert_not_includes response.body, "Continue with Google"
      assert_select "input[name='user[email]']"
    end
  end

  context "a tenant sign-on URL (#660)" do
    setup do
      @tenant = create(:tenant, name: "Null Island Systems", slug: "nullisland",
        theme: "custom", custom_theme: { "brand" => { "light" => "#aa3366", "dark" => "#bb4477" } })
      @user = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, user: @user) }
    end

    should "render the sign-in page under the tenant's name, theme and slug" do
      get tenant_sign_in_path(tenant_slug: "nullisland")

      assert_response :success
      assert_includes response.body, ">Null Island Systems</h1>"
      assert_select "input[type=hidden][name=tenant_slug][value=nullisland]"
      assert_includes response.body, "--tenant-brand:#aa3366"
    end

    should "send an unknown slug to the plain sign-in page" do
      get tenant_sign_in_path(tenant_slug: "no-such-org")

      assert_redirected_to new_user_session_path
    end

    should "scope the session to the tenant when a member signs in through it" do
      post user_session_path, params: {
        tenant_slug: "nullisland",
        user: { email: @user.email, password: "password123" }
      }

      assert_redirected_to root_path
      assert_equal @tenant.id, session[:current_tenant_id]
    end

    should "keep the sign-on tenant for a user whose FIRST membership is elsewhere" do
      # after_sign_in_path_for defaults the session to the first membership,
      # so the sign-on scoping must run after it (caught by CodeRabbit CLI).
      multi = create(:user, password: "password123")
      other = create(:tenant, name: "Other Org")
      ActsAsTenant.with_tenant(other) { create(:tenant_user, tenant: other, user: multi) }
      ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, user: multi) }

      post user_session_path, params: {
        tenant_slug: "nullisland",
        user: { email: multi.email, password: "password123" }
      }

      assert_redirected_to root_path
      assert_equal @tenant.id, session[:current_tenant_id]
    end

    should "not scope the session to a tenant the user doesn't belong to" do
      outsider = create(:user, password: "password123")

      post user_session_path, params: {
        tenant_slug: "nullisland",
        user: { email: outsider.email, password: "password123" }
      }

      assert_redirected_to root_path
      assert_not_equal @tenant.id, session[:current_tenant_id]
    end

    should "return a failed attempt to the tenant page, not the generic one" do
      post user_session_path, params: {
        tenant_slug: "nullisland",
        user: { email: @user.email, password: "wrong" }
      }

      assert_redirected_to tenant_sign_in_path(tenant_slug: "nullisland")
    end
  end
end
