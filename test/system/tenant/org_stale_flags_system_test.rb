# frozen_string_literal: true

require "application_system_test_case"

# Stale flags and "Still true" (#142) in the Units view and the person drawer.
class Tenant::OrgStaleFlagsSystemTest < ApplicationSystemTestCase
  include OrgGraphFixture

  setup do
    @tenant = FactoryBot.create(:tenant)
    @admin_user = FactoryBot.create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) do
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
    end
    @org = build_org_graph(@tenant)
    ActsAsTenant.with_tenant(@tenant) { OrgFactAge.update_all(changed_at: 100.days.ago, checked_at: 100.days.ago) }
  end

  context "at desktop width" do
    setup { page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE) }

    should "flag a stale member in the Units view and clear it with Still true" do
      sign_in_as(@admin_user)
      visit tenant_org_graph_path(unit: @org[:checkout])
      assert_selector "#org-graph-unit", text: "Checkout"
      assert_selector "[data-stale-flag=\"Cyril Moss's membership of Checkout\"]", text: "Not confirmed since"
      screenshot("units_stale")

      click_selector_with_js_fallback "button[aria-label=\"Confirm Cyril Moss's membership of Checkout is still true\"]",
                                      expect_text: "Confirmed as still true."
      assert_no_selector "[data-stale-flag=\"Cyril Moss's membership of Checkout\"]"
      assert_selector "[data-stale-flag=\"Dot Fennick's membership of Payments\"]"
      screenshot("units_confirmed")
    end
  end

  context "at phone width" do
    setup { page.driver.browser.manage.window.resize_to(*MOBILE_SIZE) }

    should "flag a stale team in the person drawer and clear it with Still true" do
      sign_in_as(@admin_user)
      visit tenant_org_person_path(@org[:brook], unit: @org[:checkout])
      assert_selector "#org-graph-drawer-title", text: "Brook Tamsin"
      within("#org-person-team-#{@org[:platform]}") { assert_text "Not confirmed since" }
      assert_no_sideways_overflow
      screenshot("person_stale_phone")

      click_selector_with_js_fallback "button[aria-label='Confirm membership of Platform is still true']",
                                      expect_text: "Confirmed as still true."
      within("#org-person-team-#{@org[:platform]}") { assert_no_text "Not confirmed since" }
      within("#org-person-team-#{@org[:checkout]}") { assert_text "Not confirmed since" }
      assert_selector "#org-graph-drawer-title", text: "Brook Tamsin"
    end
  end
end
