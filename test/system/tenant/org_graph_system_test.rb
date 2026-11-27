# frozen_string_literal: true

require "application_system_test_case"

class Tenant::OrgGraphSystemTest < ApplicationSystemTestCase
  include OrgGraphFixture

  setup do
    @tenant = FactoryBot.create(:tenant)
    @admin_user = FactoryBot.create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) do
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
    end
    @org = build_org_graph(@tenant)
  end

  context "at desktop width" do
    setup { page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE) }

    should "reach the Org Graph from the admin sidebar and open a unit from the tree" do
      sign_in_as(@admin_user)
      visit tenant_root_path
      assert_text "Tenant administration"

      click_link_with_js_fallback "Org Graph", expect_selector: "#org-graph-unit"
      screenshot("units_view")

      assert_selector "#org-graph-unit", text: "Engineering"
      assert_text "From HiBob, read-only"
      within("#unit-#{@org[:platform]}") do
        assert_text "Ada Quill"
        assert_text "Brook Tamsin"
        assert_text "also Checkout"
        assert_text "50%"
      end
      within("#in-no-team") { assert_text "Ezra Pell" }

      click_selector_with_js_fallback("nav[aria-labelledby='org-graph-tree-label'] a[href*='#{@org[:checkout]}']",
                                      expect_selector: "#unit-#{@org[:payments]}")
      screenshot("checkout_opened")

      assert_selector "#org-graph-unit", text: "Checkout"
      within("#unit-#{@org[:payments]}") { assert_text "Dot Fennick" }
      within("#unit-#{@org[:checkout]}") { assert_text "Tech lead · Engineer" }
    end
  end

  context "as a member who is not an admin" do
    setup do
      page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
      @member_user = FactoryBot.create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) do
        FactoryBot.create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)
      end
    end

    should "be turned away at the Org Graph's address" do
      sign_in_as(@member_user)
      visit tenant_org_graph_path
      assert_text "You are not authorized to perform this action."
      assert_no_selector "#org-graph-unit"
      assert_no_text "Ezra Pell"
    end
  end

  context "as Checkout's owner, who is not an admin" do
    setup do
      @owner_user = FactoryBot.create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) do
        FactoryBot.create(:tenant_user, tenant: @tenant, user: @owner_user, person: @org[:ada], role: :member)
        OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
                                         .add_unit_owner(@org[:checkout], @org[:ada].id, effective_on: Date.current)
      end
    end

    should "reach the Units view from Organisation in the app's own navigation, at desktop width" do
      page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
      sign_in_as(@owner_user)

      click_link_with_js_fallback "Organisation", expect_selector: "#org-graph-unit"
      screenshot("owner_units_view")

      assert_no_text "Tenant administration"
      assert_no_selector "a", text: "Settings"
      within("#unit-#{@org[:platform]}") { assert_text "Ada Quill" }
      assert_no_selector "#org-graph-unit a[href*='/org_graph/people/']"
    end

    should "see the Units view stacked, with no sideways scroll, at phone width" do
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      sign_in_as(@owner_user)
      visit tenant_org_graph_path(unit: @org[:checkout])

      assert_selector "#org-graph-unit", text: "Checkout"
      screenshot("owner_units_view_phone")
      assert_no_text "Tenant administration"
      assert_no_sideways_overflow
    end
  end

  context "at phone width" do
    setup { page.driver.browser.manage.window.resize_to(*MOBILE_SIZE) }

    should "stack the tree above the unit with no sideways scroll" do
      sign_in_as(@admin_user)
      visit tenant_org_graph_path
      assert_selector "#org-graph-unit", text: "Engineering"
      screenshot("units_view_phone")

      tree = find("nav[aria-labelledby='org-graph-tree-label']")
      unit = find("#org-graph-unit")
      assert_operator tree.rect.y + tree.rect.height, :<=, unit.rect.y
      within("#in-no-team") { assert_text "Ezra Pell" }
      assert_no_sideways_overflow
    end
  end
end
