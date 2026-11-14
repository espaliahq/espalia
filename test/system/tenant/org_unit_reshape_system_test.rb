# frozen_string_literal: true

require "application_system_test_case"

# Split, merge and retire from the unit drawer (#138).
class Tenant::OrgUnitReshapeSystemTest < ApplicationSystemTestCase
  include OrgGraphFixture

  setup do
    @tenant = FactoryBot.create(:tenant)
    @admin_user = FactoryBot.create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) do
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
    end
    @org = build_org_graph(@tenant)
  end

  def unit(key) = ActsAsTenant.with_tenant(@tenant) { OrgUnit.find(@org[key]) }

  def units_of(person)
    ActsAsTenant.with_tenant(@tenant) { OrgMembership.where(person_id: @org[person].id).map { it.unit.name }.sort }
  end

  context "at desktop width" do
    setup { page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE) }

    should "split a unit, showing who will be in no team before it applies" do
      sign_in_as(@admin_user)
      visit edit_tenant_org_unit_path(@org[:platform])
      assert_selector "#org-graph-drawer-title", text: "Platform"

      click_link_with_js_fallback "Split", expect_text: "First new unit"
      js_fill_in "First new unit", with: "Core"
      js_fill_in "Second new unit", with: "Edge"
      click_button_with_js_fallback "Next: place people", expect_text: "Choose a new unit for each person."

      select "Core", from: "Ada Quill"
      click_button_with_js_fallback "Review the split", expect_selector: "#org-unit-split-unplaced"
      screenshot("split_review")
      within("#org-unit-split-staying li", text: "Brook Tamsin") { assert_text "stays in Checkout" }
      within("ul[aria-label='Moving to Core']") { assert_text "Ada Quill" }

      click_button_with_js_fallback "Split Platform", expect_text: "Split Platform into Core and Edge."
      assert unit(:platform).retired?
      assert_equal [ "Core" ], units_of(:ada)
      assert_selector "nav[aria-labelledby='org-graph-tree-label']", text: "Edge"
    end

    should "say a unit with sub-units can't retire, and name the provider of a mirrored one" do
      sign_in_as(@admin_user)
      visit edit_tenant_org_unit_path(@org[:checkout])
      assert_selector "#org-graph-drawer-title", text: "Checkout"

      click_link_with_js_fallback "Retire", expect_selector: "#org-unit-step-blocked"
      assert_text "Move or retire Checkout's sub-units first: Payments."
      assert_no_button "Retire Checkout"

      visit edit_tenant_org_unit_path(@org[:engineering])
      assert_selector "#org-graph-drawer-title", text: "Engineering"
      within("section[aria-labelledby='org-unit-reshape']") do
        assert_text "HiBob holds Engineering, so split, merge or retire it there."
        assert_no_link "Retire"
      end
    end
  end

  context "at phone width" do
    setup { page.driver.browser.manage.window.resize_to(*MOBILE_SIZE) }

    should "merge one unit into another, and retire an empty one" do
      sign_in_as(@admin_user)
      visit edit_tenant_org_unit_path(@org[:payments])
      assert_selector "#org-graph-drawer-title", text: "Payments"

      click_link_with_js_fallback "Merge", expect_selector: "#org-unit-merge-into"
      within("ul[aria-label='People moving from Payments']") { assert_text "Dot Fennick" }
      assert_no_sideways_overflow
      screenshot("merge_phone")
      select "\u2003Platform", from: "Merge into"
      click_button_with_js_fallback "Merge Payments", expect_text: "Merged Payments into Platform."
      assert_equal [ "Platform" ], units_of(:dot)

      visit edit_tenant_org_unit_path(@org[:checkout])
      assert_selector "#org-graph-drawer-title", text: "Checkout"
      tomorrow = Date.tomorrow.iso8601
      js_fill_in "Changes take effect", with: tomorrow
      click_link_with_js_fallback "Retire", expect_text: "ends 2 memberships"
      assert_field "Takes effect", with: tomorrow
      assert_no_sideways_overflow
      screenshot("retire_phone")
      click_button_with_js_fallback "Retire Checkout", expect_text: "Retired Checkout. 2 memberships ended."
      assert unit(:checkout).retired?
    end
  end
end
