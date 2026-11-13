# frozen_string_literal: true

require "application_system_test_case"

class Tenant::OrgGraphCompareSystemTest < ApplicationSystemTestCase
  include OrgGraphFixture

  setup do
    @tenant = FactoryBot.create(:tenant)
    @admin_user = FactoryBot.create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) do
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
    end
    @org = build_org_graph(@tenant)
    @today = Date.current
    ActsAsTenant.with_tenant(@tenant) do
      OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
                                       .rename_unit(@org[:platform], "Core Platform", effective_on: @today - 10)
      OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
                              .move_membership(@org[:ada].id, @org[:platform], @org[:checkout], effective_on: @today - 5)
    end
    sign_in_as(@admin_user)
  end

  def tree_link(unit_key) = "nav[aria-labelledby='org-graph-tree-label'] a[href*='#{@org[unit_key]}']"

  context "at desktop width" do
    setup { page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE) }

    should "pick a date, see what changed in the tree and on the cards, and keep the window while moving between units" do
      visit tenant_org_graph_path
      assert_selector "#org-graph-unit", text: "Engineering"
      assert_no_text "was Platform"

      click_selector_with_js_fallback("#org-graph-comparison summary", expect_selector: "#comparison-from")
      js_fill_in "#comparison-from", with: (@today - 30).iso8601
      click_button_with_js_fallback "Compare", expect_text: "What changed"
      screenshot("compared")

      within(tree_link(:platform)) { assert_text "was Platform" }
      within("#unit-#{@org[:platform]}") { assert_text "Ada Quill moved to Checkout" }
      within("#unit-#{@org[:checkout]}") { assert_text "Ada Quill moved in from Core Platform" }
      within("#org-graph-comparison dl") do
        assert_text "Moved\n1"
        assert_text "Renamed\n1"
      end
      assert_no_text "in UTC"

      click_selector_with_js_fallback(tree_link(:checkout), expect_selector: "#unit-#{@org[:payments]}")
      assert_selector "#org-graph-unit", text: "Checkout"
      within("#unit-#{@org[:checkout]}") { assert_text "Ada Quill moved in from Core Platform" }
    end

    should "switch to what the Org Graph learned in the window, and say the window runs in UTC" do
      visit tenant_org_graph_path(from: (@today - 30).iso8601)
      assert_text "What changed"

      js_set_checkbox "We learned in the window", checked: true
      click_button_with_js_fallback "Compare", expect_text: "in UTC"
      screenshot("learned")

      within("#unit-#{@org[:checkout]}") { assert_text "Ada Quill moved in from Core Platform" }
      assert_text "learned #{I18n.l(@today, format: '%-d %b')}"
    end

    should "refuse an end date before the date compared with, and mark nothing" do
      visit tenant_org_graph_path(from: (@today - 5).iso8601, to: (@today - 10).iso8601)

      assert_text "Pick an end date on or after the date you compare with."
      assert_no_text "was Platform"
    end
  end

  context "at phone width" do
    setup { page.driver.browser.manage.window.resize_to(*MOBILE_SIZE) }

    should "show the counts and the marks with no sideways scroll" do
      visit tenant_org_graph_path(from: (@today - 30).iso8601)
      assert_text "What changed"
      screenshot("compared_phone")

      within(tree_link(:platform)) { assert_text "was Platform" }
      within("#unit-#{@org[:checkout]}") { assert_text "Ada Quill moved in from Core Platform" }
      assert_no_sideways_overflow
    end
  end
end
