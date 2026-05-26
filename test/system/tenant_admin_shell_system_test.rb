# frozen_string_literal: true

require "application_system_test_case"

# Exercises the tenant admin shell — sidebar navigation across the
# three sections (Theme, Users, Integrations) and the dashboard
# landing page.
#
class TenantAdminShellSystemTest < ApplicationSystemTestCase
  setup do
    @tenant = FactoryBot.create(:tenant, :with_hibob_config)
    @admin_user = FactoryBot.create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
    end

    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
  end

  should "render the dashboard with three tiles for admins" do
    sign_in_as(@admin_user)
    visit tenant_root_path
    screenshot("tenant_dashboard")

    assert_text "Tenant administration"
    # Tiles
    assert_link "Theme", href: "/tenant/theme"
    assert_link "Users", href: "/tenant/users"
    assert_link "Integrations", href: "/tenant/integrations"
  end

  should "navigate between sections via the sidebar" do
    sign_in_as(@admin_user)
    visit tenant_root_path
    assert_text "Tenant administration"

    click_link_with_js_fallback "Theme", expect_text: "Brand colors"
    assert_current_path tenant_theme_path

    click_link_with_js_fallback "Users", expect_text: "Tenant users"
    assert_current_path tenant_users_path

    click_link_with_js_fallback "Integrations", expect_text: "HRIS"
    assert_current_path tenant_integrations_path
  end
end
