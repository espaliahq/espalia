# frozen_string_literal: true

require "application_system_test_case"

# Screenshot-driven visual verification of the live theme preview.
# Run with SCREENSHOTS=1 and review each captured frame to confirm the
# brand color visibly changed on the page chrome (primary button
# accent, nav background) — not just in CSS variables.
#
#   SCREENSHOTS=1 bin/rails test test/system/tenant_theme_preview_screenshot_test.rb
#
# The /screenshot-test skill walks the saved frames in
# tmp/screenshots/TenantThemePreviewScreenshotTest/ to confirm.
#
class TenantThemePreviewScreenshotTest < ApplicationSystemTestCase
  setup do
    @tenant = FactoryBot.create(:tenant)
    @admin_user = FactoryBot.create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
    end

    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    sign_in_as(@admin_user)
  end

  should "capture each live-preview state for visual review" do
    visit tenant_theme_path
    wait_for_stimulus "theme-live-preview"
    screenshot("01_initial_state")

    # High-contrast magenta — easy to eyeball against the default teal
    set_color_field("tenant[custom_theme][brand][light]", "#ff0080")
    screenshot("02_primary_changed_to_magenta")

    # Dark navy nav for contrast against magenta primary
    set_color_field("tenant[custom_theme][nav-surface][light]", "#101820")
    screenshot("03_nav_bg_changed_to_navy")

    click_cancel
    screenshot("04_after_cancel_restored")

    set_color_field("tenant[custom_theme][brand][light]", "#7c3aed")
    click_button_with_js_fallback "Save", expect_text: "#7c3aed"
    assert_current_path tenant_theme_path
    screenshot("05_after_save")

    visit tenant_root_path
    screenshot("06_dashboard_after_reload_persisted_theme")
  end

  private

  def set_color_field(name, hex)
    page.execute_script(<<~JS)
      const el = document.querySelector('input[name="#{name}"]');
      el.value = "#{hex}";
      el.dispatchEvent(new Event("input", { bubbles: true }));
    JS
  end

  # JS-dispatch click on the Cancel button (Stimulus-action element).
  def click_cancel
    page.execute_script(
      "document.querySelector('[data-action~=\"theme-live-preview#revert\"]').click()"
    )
  end
end
