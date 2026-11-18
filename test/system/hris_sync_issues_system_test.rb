# frozen_string_literal: true

require "application_system_test_case"

# A unit the HRIS places inside a declared structure stays where it was, and
# an admin finds out why from its drawer and the HRIS page (#494).
class HrisSyncIssuesSystemTest < ApplicationSystemTestCase
  include OrgGraphFixture

  setup do
    @tenant = FactoryBot.create(:tenant, :with_hibob_config)
    @org = build_org_graph(@tenant)
    @admin_user = FactoryBot.create(:user)
    ActsAsTenant.with_tenant(@tenant) do
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      FactoryBot.create(:hris_sync_issue, tenant: @tenant, unit_id: @org[:payments], parent_id: @org[:checkout],
                                          structure_unit_id: @org[:engineering])
    end
  end

  { "desktop" => DESKTOP_SIZE, "mobile" => MOBILE_SIZE }.each do |viewport, size|
    context "at #{viewport}" do
      setup do
        page.driver.browser.manage.window.resize_to(*size)
        sign_in_as(@admin_user)
      end

      should "follow the drawer's sync issue to the HRIS page's list" do
        visit edit_tenant_org_unit_path(@org[:payments])
        within("#org-unit-sync-issues") { assert_text "under Checkout, inside Engineering's own structure" }

        click_link_with_js_fallback "See every sync issue", expect_selector: "#sync-issues"

        within("#sync-issues tr[data-sync-issue='#{@org[:payments]}']") do
          assert_text "Payments"
          assert_text "Checkout"
          assert_text "Engineering"
          assert_text "16 Nov 2026"
        end
        assert_no_sideways_overflow
      end
    end
  end

  should "keep the first seen day off a phone's table" do
    page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
    sign_in_as(@admin_user)
    visit tenant_integration_path("hris")

    within("#sync-issues") do
      assert_selector "th", text: /last seen/i
      assert_no_selector "th", text: /first seen/i
    end
  end
end
