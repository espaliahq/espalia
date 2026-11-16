# frozen_string_literal: true

require "application_system_test_case"

# The Time zone page: the date today is shows for the zone picked before it
# is saved, and saving moves the tenant's today (#469).
class Tenant::TimeZoneSystemTest < ApplicationSystemTestCase
  setup do
    @tenant = FactoryBot.create(:tenant)
    @admin_user = FactoryBot.create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) { FactoryBot.create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin) }
  end

  [ [ "desktop", ApplicationSystemTestCase::DESKTOP_SIZE ], [ "mobile", ApplicationSystemTestCase::MOBILE_SIZE ] ].each do |name, size|
    should "preview today in the zone picked, then save it (#{name})" do
      page.driver.browser.manage.window.resize_to(*size)
      sign_in_as(@admin_user)
      visit tenant_time_zone_path
      wait_for_stimulus "zone-today"

      select_zone "Pacific/Tongatapu"
      assert_selector "[data-zone-today-target='date']", text: expected_today("Pacific/Tongatapu")

      select_zone "Pacific/Pago_Pago"
      assert_selector "[data-zone-today-target='date']", text: expected_today("Pacific/Pago_Pago")

      click_button_with_js_fallback "Save", expect_text: "Today is now"
      assert_equal "Pacific/Pago_Pago", @tenant.reload.time_zone
      assert_text "Today is now #{expected_today('Pacific/Pago_Pago')} in Pacific/Pago_Pago."
    end
  end

  private

  def select_zone(identifier)
    find("select#tenant_time_zone option[value='#{identifier}']").select_option
  end

  def expected_today(zone) = Time.current.in_time_zone(zone).strftime("%A %-d %B %Y")
end
