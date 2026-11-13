# frozen_string_literal: true

require "application_system_test_case"

# The unit drawer (#124), opened from the Units view.
class Tenant::OrgUnitDrawerSystemTest < ApplicationSystemTestCase
  include OrgGraphFixture

  setup do
    @tenant = FactoryBot.create(:tenant)
    @admin_user = FactoryBot.create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) do
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
    end
    @org = build_org_graph(@tenant)
  end

  def membership(person, key)
    ActsAsTenant.with_tenant(@tenant) { OrgMembership.find_by(person_id: @org[person].id, unit_id: @org[key]) }
  end

  def inert_count = page.evaluate_script("document.querySelectorAll('[inert]').length")

  context "at desktop width" do
    setup { page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE) }

    should "rename a unit, back-date it, and staff it from the drawer beside the Units view" do
      sign_in_as(@admin_user)
      visit tenant_org_graph_path(unit: @org[:platform])
      assert_selector "#org-graph-unit", text: "Platform"

      click_link_with_js_fallback "Edit unit", expect_selector: "#org-graph-drawer"
      screenshot("drawer_open")
      within("#org-graph-drawer") { assert_text "Ada Quill" }
      assert_selector "nav[aria-labelledby='org-graph-tree-label']", visible: true
      assert_equal 0, inert_count, "beside the page, the drawer leaves it usable"

      wait_for_stimulus "effective-date"
      js_fill_in "Changes take effect", with: "2026-11-02"
      js_fill_in "org-unit-name", with: "Core Platform"
      click_button_with_js_fallback "Rename", expect_text: "Renamed."

      assert_selector "#org-graph-drawer-title", text: "Core Platform"
      assert_selector "nav[aria-labelledby='org-graph-tree-label']", text: "Core Platform"
      assert_equal "2026-11-02", find_field("Changes take effect").value
      assert_equal "Core Platform", ActsAsTenant.with_tenant(@tenant) { OrgUnit.find(@org[:platform]).name }

      wait_for_stimulus "person-picker", scope: "[data-person-picker-frame-id-value='member-candidates']"
      js_fill_in "Add people", with: "Ezra"
      assert_selector "turbo-frame#member-candidates button", text: "Ezra Pell"
      page.execute_script(
        %{document.querySelector("turbo-frame#member-candidates [data-person-picker-person-id-param='#{@org[:ezra].id}']").click()}
      )
      assert_selector "[data-person-picker-target='selected'] span[data-person-id='#{@org[:ezra].id}']"
      js_fill_in "Role (optional)", with: "Analyst"
      click_button_with_js_fallback "Add to Core Platform", expect_text: "Added to Core Platform."
      screenshot("member_added")

      within("#org-unit-member-#{@org[:ezra].id}") { assert_text "Analyst" }
      assert_equal "2026-11-02", membership(:ezra, :platform).effective_on.iso8601

      click_selector_with_js_fallback "button[aria-label='Remove Brook Tamsin from Core Platform']",
                                      expect_text: "Removed from Core Platform."
      assert_no_selector "#org-unit-member-#{@org[:brook].id}"
    end

    should "hold a change back while the date is cleared" do
      sign_in_as(@admin_user)
      visit edit_tenant_org_unit_path(@org[:platform])
      wait_for_stimulus "effective-date"

      js_fill_in "Changes take effect", with: ""
      js_fill_in "org-unit-name", with: "Core Platform"
      page.execute_script("document.querySelector('#org-graph-drawer form:has(#org-unit-name) button[type=submit]').click()")

      assert_selector "#org-unit-effective-on:focus"
      assert_no_text "Renamed."
      assert_equal "Platform", ActsAsTenant.with_tenant(@tenant) { OrgUnit.find(@org[:platform]).name }
    end

    should "keep an HRIS unit's name and parent read-only" do
      sign_in_as(@admin_user)
      visit edit_tenant_org_unit_path(@org[:engineering])

      within("#org-graph-drawer") do
        assert_text "From HiBob: change its name and parent there."
        assert_no_field "org-unit-name"
        assert_no_select "org-unit-parent"
        assert_button "Add owner"
      end
    end
  end

  context "at phone width" do
    setup { page.driver.browser.manage.window.resize_to(*MOBILE_SIZE) }

    should "cover the page, keep focus inside the drawer, and move a member" do
      sign_in_as(@admin_user)
      visit tenant_org_graph_path(unit: @org[:checkout])
      assert_selector "#org-graph-unit", text: "Checkout"

      click_link_with_js_fallback "Edit unit", expect_selector: "#org-graph-drawer"
      wait_for_stimulus "drawer-isolation"
      screenshot("drawer_phone")

      assert_operator inert_count, :>, 0
      assert page.evaluate_script(
        "!!document.querySelector(\"nav[aria-labelledby='org-graph-tree-label']\").closest('[inert]')"
      ), "the tree behind the drawer leaves the tab order"
      assert_equal "org-graph-drawer-title", page.evaluate_script("document.activeElement.id")
      assert_no_sideways_overflow

      select "  Payments", from: "Move Cyril Moss to"
      click_selector_with_js_fallback "button[aria-label='Move Cyril Moss']", expect_text: "Moved."
      assert_nil membership(:cyril, :checkout)
      assert membership(:cyril, :payments)

      assert_not page.evaluate_script("!!document.querySelector('[data-toast-stack]').closest('[inert]')"),
                 "the toast saying what changed stays live"

      click_selector_with_js_fallback "#org-graph-drawer a[aria-label='Close']",
                                      expect_selector: "body:not(:has(#org-graph-drawer)) #org-graph-unit"
      assert_equal 0, inert_count, "closing the drawer gives the page back"
    end
  end
end
