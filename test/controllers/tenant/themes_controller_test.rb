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
        assert_includes response.body, "theme-live-preview"
        assert_select "input[type=radio][name='tenant[theme]']", 3
        assert_select "input[type=radio][value=default][checked]"
        assert_select "fieldset[hidden][disabled] input[name='tenant[custom_theme][brand][light]']"
        assert_select "input[name='tenant[custom_theme][nav-surface][dark]']"
        assert_select "iframe[src='#{preview_tenant_theme_path(theme_name: "bento", colour_scheme: "dark")}']"
      end

      should "offer a picker for every role roles.css lets a Custom theme set, starting at Default's value" do
        defaults = Tenant::CUSTOM_ROLE_DEFAULTS.merge("accent" => { "light" => "#123456", "dark" => "#654321" })
        with_custom_role_defaults(defaults) { get tenant_theme_path }

        defaults.each do |role, schemes|
          schemes.each do |scheme, hex|
            assert_select "input[type=color][name='tenant[custom_theme][#{role}][#{scheme}]'][value='#{hex}']"
          end
        end
      end

      should "show Custom's controls with the stored values when the theme is Custom" do
        @tenant.update!(theme: "custom", custom_theme: { "brand" => { "light" => "#abcdef" } })
        get tenant_theme_path
        assert_select "input[type=radio][value=custom][checked]"
        assert_select "fieldset:not([hidden]) input[name='tenant[custom_theme][brand][light]'][value='#abcdef']"
      end
    end

    context "GET /tenant/theme/preview" do
      should "render the preset in the scheme asked for" do
        get preview_tenant_theme_path(theme_name: "bento", colour_scheme: "dark")
        assert_response :success
        assert_select "html[data-theme=bento][data-scheme=dark]"
        assert_select "body[inert] nav"
      end

      should "render Custom with the stored values even while a preset is on" do
        @tenant.update!(theme: "bento", custom_theme: { "brand" => { "light" => "#abcdef" } })
        get preview_tenant_theme_path(theme_name: "custom", colour_scheme: "light")
        assert_select "html:not([data-theme])[data-scheme=light]"
        assert_includes response.body, "--tenant-brand:#abcdef"
      end

      should "fall back to Default in light for unknown values" do
        get preview_tenant_theme_path(theme_name: "nope", colour_scheme: "dim")
        assert_select "html:not([data-theme])[data-scheme=light]"
        assert_not_includes response.body, "--tenant-"
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

      should "save a preset" do
        patch tenant_theme_path, params: { tenant: { theme: "bento" } }
        assert_redirected_to tenant_theme_path
        assert_equal "bento", @tenant.reload.theme
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

    should "deny GET preview" do
      get preview_tenant_theme_path(theme_name: "bento", colour_scheme: "dark")
      assert_response :redirect
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

  # Stands in for a new `--tenant-*` hook in roles.css, which is read once at boot.
  def with_custom_role_defaults(defaults)
    original = Themeable::CUSTOM_ROLE_DEFAULTS
    swap = ->(value) do
      silence_warnings do
        Themeable.const_set(:CUSTOM_ROLE_DEFAULTS, value)
        Themeable.const_set(:CUSTOM_ROLES, value.keys)
      end
    end
    swap.(defaults)
    yield
  ensure
    swap.(original)
  end
end
