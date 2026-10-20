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
        assert_select "input[name='tenant[custom_theme][brand][light]']"
        assert_select "input[name='tenant[custom_theme][nav-surface][dark]']"
      end
    end

    context "PATCH /tenant/theme" do
      should "save the form as a Custom theme" do
        patch tenant_theme_path, params: {
          tenant: {
            theme: "custom",
            custom_theme: { brand: { light: "#abcdef", dark: "#123456" } },
            font_family: "Roboto"
          }
        }
        assert_redirected_to tenant_theme_path
        follow_redirect!
        assert_equal "Theme saved.", flash[:notice]

        @tenant.reload
        assert_equal "custom", @tenant.theme
        assert_equal "#abcdef", @tenant.custom_role("brand", :light)
        assert_equal "#123456", @tenant.custom_role("brand", :dark)
        assert_equal "Roboto", @tenant.font_family
      end

      should "redirect with an alert on a malformed hex color" do
        patch tenant_theme_path, params: {
          tenant: { theme: "custom", custom_theme: { brand: { light: "not-a-hex" } } }
        }
        assert_response :see_other
        follow_redirect!
        assert_includes flash[:alert], "Theme could not be saved"
        assert_equal({}, @tenant.reload.custom_theme)
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
      patch tenant_theme_path, params: {
        tenant: { theme: "custom", custom_theme: { brand: { light: "#abcdef" } } }
      }
      assert_response :redirect
      @tenant.reload
      assert_equal "default", @tenant.theme
      assert_equal({}, @tenant.custom_theme)
    end
  end

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end
