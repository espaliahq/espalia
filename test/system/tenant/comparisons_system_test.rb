# frozen_string_literal: true

require "application_system_test_case"

# Tenant admin → Comparisons, at both widths.
class Tenant::ComparisonsSystemTest < ApplicationSystemTestCase
  setup do
    @tenant = FactoryBot.create(:tenant)
    @admin_user = FactoryBot.create(:user)
    ActsAsTenant.with_tenant(@tenant) do
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
    end
  end

  { "desktop" => DESKTOP_SIZE, "mobile" => MOBILE_SIZE }.each do |viewport, size|
    should "turn comparisons off and take snapshots less often at #{viewport}" do
      page.driver.browser.manage.window.resize_to(*size)
      sign_in_as(@admin_user)
      visit tenant_comparisons_path
      assert_text "How snapshots work"
      assert_no_sideways_overflow

      js_set_checkbox("Let people compare with their level", checked: false)
      js_fill_in "Smallest group to compare with", with: "7"
      select "3 months", from: "Take a new snapshot every"
      click_button_with_js_fallback("Save", expect_text: "Comparisons are off. Saved.")

      config = @tenant.reload.comparison_config
      assert_equal [ false, 7, 3 ], [ config.enabled, config.min_group_size, config.snapshot_every_months ]
    end
  end
end
