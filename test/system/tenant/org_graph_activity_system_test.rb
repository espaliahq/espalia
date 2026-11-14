# frozen_string_literal: true

require "application_system_test_case"

class Tenant::OrgGraphActivitySystemTest < ApplicationSystemTestCase
  include OrgGraphFixture

  SIDEBAR = "##{Views::Tenant::OrgGraph::Sidebar::ID}".freeze

  setup do
    @tenant = FactoryBot.create(:tenant)
    @admin_user = FactoryBot.create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) do
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
    end
    @org = build_org_graph(@tenant)
    ActsAsTenant.with_tenant(@tenant) do
      OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM, cause_id: "reorg-1").tap do |handler|
        handler.move_membership(@org[:cyril].id, @org[:checkout], @org[:platform], effective_on: "2026-02-01")
        handler.move_membership(@org[:dot].id, @org[:payments], @org[:platform], effective_on: "2026-02-01")
      end
    end
  end

  def change_back_button(field, value) = "#{SIDEBAR} form:has(input[name='#{field}'][value='#{value}']) button"

  def brook_added
    ActsAsTenant.with_tenant(@tenant) do
      OrgUnitActivity.for_unit(@org[:platform]).find_by!(person_id: @org[:brook].id, event_type: "MembershipSet")
    end
  end

  context "at desktop width" do
    setup { page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE) }

    should "show the opened unit's activity beside it, open a group's parts and change one back" do
      sign_in_as(@admin_user)
      visit tenant_org_graph_path(unit: @org[:platform])

      sidebar = find(SIDEBAR)
      assert_operator find("#org-graph-unit").rect.x, :<, sidebar.rect.x, "the sidebar sits beside the unit"
      within(SIDEBAR) do
        assert_text "Moved 2 people in"
        assert_text "This changes it back in all 3 units it touched."
        assert_text "Can't change back: Unit Created can't be changed back"
        find("summary", text: "Show 2 parts").click
        assert_text "Moved Cyril Moss in from Checkout"
      end
      screenshot("activity_sidebar")

      click_selector_with_js_fallback(change_back_button("entry_id", brook_added.id), expect_text: "Changed back.")

      within(SIDEBAR) do
        assert_text "Removed Brook Tamsin"
        assert_selector "li", text: /Added Brook Tamsin.*Changed back/m
      end
      within("#unit-#{@org[:platform]}") { assert_no_text "Brook Tamsin" }
    end

    should "change a whole group back, in every unit it touched" do
      sign_in_as(@admin_user)
      visit tenant_org_graph_path(unit: @org[:platform])

      click_selector_with_js_fallback(change_back_button("cause_id", "reorg-1"), expect_text: "Changed back.")

      within(SIDEBAR) { assert_text "Moved 2 people out" }
      within("#unit-#{@org[:platform]}") { assert_no_text "Cyril Moss" }
      visit tenant_org_graph_path(unit: @org[:payments])
      within("#unit-#{@org[:payments]}") { assert_text "Dot Fennick" }
    end
  end

  context "at phone width" do
    setup { page.driver.browser.manage.window.resize_to(*MOBILE_SIZE) }

    should "put the activity below the unit with no sideways scroll" do
      sign_in_as(@admin_user)
      visit tenant_org_graph_path(unit: @org[:platform])
      assert_selector SIDEBAR, text: "Moved 2 people in"
      screenshot("activity_sidebar_phone")

      unit = find("#org-graph-unit")
      assert_operator unit.rect.y, :<, find(SIDEBAR).rect.y
      assert_no_sideways_overflow
      assert_no_stolen_taps
    end
  end
end
