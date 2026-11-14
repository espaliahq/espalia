# frozen_string_literal: true

require "application_system_test_case"

# The person drawer (#132), opened from a member row or the "In no team" tray.
class Tenant::OrgPersonDrawerSystemTest < ApplicationSystemTestCase
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

  def choose(select_id, key)
    page.execute_script(<<~JS)
      const select = document.getElementById("#{select_id}")
      select.value = "#{@org[key]}"
      select.dispatchEvent(new Event("change", { bubbles: true }))
    JS
  end

  context "at desktop width" do
    setup { page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE) }

    should "open someone from the tray, add them to a team from a chosen date, then move it" do
      sign_in_as(@admin_user)
      visit tenant_org_graph_path
      assert_selector "#org-graph-unit"

      click_link_with_js_fallback "Ezra Pell", expect_selector: "#org-graph-drawer-title"
      within("#org-graph-drawer") { assert_text "In no team." }
      screenshot("person_open")

      wait_for_stimulus "effective-date"
      js_fill_in "Changes take effect", with: "2026-11-02"
      choose("org-person-join", :platform)
      js_fill_in "Role (optional)", with: "Analyst"
      js_fill_in "Allocation %", with: "40"
      click_button_with_js_fallback "Add to team", expect_text: "Added to Platform."
      screenshot("person_added")

      within("#org-person-team-#{@org[:platform]}") { assert_text "Analyst · 40%" }
      within("#org-graph-drawer") { assert_text "Joined Platform as Analyst at 40%" }
      assert_equal [ Date.new(2026, 11, 2), 0.4 ], membership(:ezra, :platform).then { [ it.member_since, it.allocation ] }
      assert_equal "2026-11-02", find_field("Changes take effect").value

      choose("org-person-move-#{@org[:platform]}", :payments)
      click_selector_with_js_fallback "button[aria-label='Move from Platform']", expect_text: "Moved to Payments."
      assert_nil membership(:ezra, :platform)
      assert membership(:ezra, :payments)
    end
  end

  context "at phone width" do
    setup { page.driver.browser.manage.window.resize_to(*MOBILE_SIZE) }

    should "open a member from their unit and end one of their teams" do
      sign_in_as(@admin_user)
      visit tenant_org_graph_path(unit: @org[:checkout])
      assert_selector "#org-graph-unit", text: "Checkout"

      click_link_with_js_fallback "Brook Tamsin", expect_selector: "#org-graph-drawer-title"
      wait_for_stimulus "drawer-isolation"
      within("#org-graph-drawer") { assert_text "Tech lead · 50%" }
      assert_no_sideways_overflow
      screenshot("person_phone")

      click_selector_with_js_fallback "button[aria-label='End membership of Checkout']", expect_text: "Left Checkout."
      assert_no_selector "#org-person-team-#{@org[:checkout]}"
      assert_nil membership(:brook, :checkout)

      click_selector_with_js_fallback "#org-graph-drawer a[aria-label='Close']",
                                      expect_selector: "body:not(:has(#org-graph-drawer)) #org-graph-unit"
      assert_selector "#org-graph-unit", text: "Checkout"
    end
  end
end
