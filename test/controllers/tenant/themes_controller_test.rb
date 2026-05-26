# frozen_string_literal: true

require "test_helper"

class Tenant::ThemesControllerTest < ActionDispatch::IntegrationTest
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

    context "GET /tenant/theme" do
      should "render the theme editor" do
        get tenant_theme_path
        assert_response :success
        assert_includes response.body, "Brand colors"
        assert_includes response.body, "Typography"
        assert_includes response.body, "theme-live-preview"
      end
    end

    context "PATCH /tenant/theme" do
      should "persist supplied theme attributes" do
        patch tenant_theme_path, params: {
          tenant: {
            primary_color: "#abcdef",
            font_family: "Roboto"
          }
        }
        assert_redirected_to tenant_theme_path
        follow_redirect!
        assert_equal "Theme saved.", flash[:notice]

        @tenant.reload
        assert_equal "#abcdef", @tenant.primary_color
        assert_equal "Roboto", @tenant.font_family
      end

      should "redirect with an alert on a malformed hex color" do
        patch tenant_theme_path, params: {
          tenant: { primary_color: "not-a-hex" }
        }
        assert_response :see_other
        follow_redirect!
        assert_includes flash[:alert], "Theme could not be saved"
        @tenant.reload
        assert_nil @tenant.primary_color
      end
    end
  end

  context "as a tenant member" do
    setup { sign_in @member_user }

    should "deny GET show" do
      get tenant_theme_path
      assert_response :redirect
      follow_redirect!
      assert_includes flash[:alert], "not authorized"
    end

    should "deny PATCH update" do
      patch tenant_theme_path, params: { tenant: { primary_color: "#abcdef" } }
      assert_response :redirect
      @tenant.reload
      assert_nil @tenant.primary_color
    end
  end

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end
