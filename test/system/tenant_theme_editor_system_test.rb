# frozen_string_literal: true

require "application_system_test_case"

# Verifies the theme editor's live preview wiring and persistence.
# The screenshot-driven visual verification of the *rendered* preview
# lives in tenant_theme_preview_screenshot_test.rb.
#
class TenantThemeEditorSystemTest < ApplicationSystemTestCase
  setup do
    @tenant = FactoryBot.create(:tenant)
    @admin_user = FactoryBot.create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
    end

    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    sign_in_as(@admin_user)
  end

  should "update the --color-primary CSS variable live on input change" do
    visit tenant_theme_path
    wait_for_stimulus "theme-live-preview"

    new_color = "#ff8800"
    set_color_field("tenant[primary_color]", new_color)

    applied = page.evaluate_script(
      "document.documentElement.style.getPropertyValue('--color-primary').trim()"
    )
    assert_equal new_color, applied
  end

  should "restore the default and re-apply when Cancel is clicked" do
    visit tenant_theme_path
    wait_for_stimulus "theme-live-preview"

    original_color = page.evaluate_script(
      "document.querySelector('input[name=\"tenant[primary_color]\"]')" \
      ".dataset.themeLivePreviewDefaultParam"
    )

    set_color_field("tenant[primary_color]", "#ff8800")
    click_button "Cancel"

    applied = page.evaluate_script(
      "document.documentElement.style.getPropertyValue('--color-primary').trim()"
    )
    assert_equal original_color, applied
  end

  should "persist saved colors so they appear in tenant-theme stylesheet on reload" do
    visit tenant_theme_path
    wait_for_stimulus "theme-live-preview"

    set_color_field("tenant[primary_color]", "#abcdef")
    click_button "Save"

    # Land back on the editor; the persisted value rendered next to
    # the input is a stable signal that the round-trip completed,
    # without racing the 5s flash auto-dismiss.
    assert_current_path tenant_theme_path
    assert_text "#abcdef"

    @tenant.reload
    assert_equal "#abcdef", @tenant.primary_color

    style = page.evaluate_script(
      "document.querySelector('#tenant-theme')?.textContent || ''"
    )
    assert_includes style, "--color-primary:#abcdef"
  end

  private

  # Color inputs don't respond to `fill_in` reliably across browsers.
  # Setting `value` + dispatching `input` mirrors what a user dragging
  # the color picker would trigger — the same path the Stimulus
  # controller listens on.
  def set_color_field(name, hex)
    page.execute_script(<<~JS)
      const el = document.querySelector('input[name="#{name}"]');
      el.value = "#{hex}";
      el.dispatchEvent(new Event("input", { bubbles: true }));
    JS
  end
end
